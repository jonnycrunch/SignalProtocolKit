//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

#import <25519/Curve25519.h>
#import "AxolotlInMemoryStore.h"
#import "AliceAxolotlParameters.h"
#import "BobAxolotlParameters.h"
#import "RatchetingSession.h"
#import "SessionBuilder.h"
#import "SessionCipher.h"
#import "Chainkey.h"

#import "SessionState.h"

@interface SessionCipherTest : XCTestCase

@property (nonatomic, readonly) NSString *aliceIdentifier;
@property (nonatomic, readonly) NSString *bobIdentifier;
@property (nonatomic, readonly) AxolotlInMemoryStore *aliceStore;
@property (nonatomic, readonly) AxolotlInMemoryStore *bobStore;

@end

@implementation SessionCipherTest

- (NSString *)aliceIdentifier
{
    return @"+3728378173821";
}

- (NSString *)bobIdentifier
{
    return @"bob@gmail.com";
}

- (void)setUp {
    [super setUp];
    _aliceStore = [AxolotlInMemoryStore new];
    _bobStore = [AxolotlInMemoryStore new];
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testBasicSession{
    SessionRecord *aliceSessionRecord = [SessionRecord new];
    SessionRecord *bobSessionRecord   = [SessionRecord new];

    [self sessionInitializationWithAliceSessionRecord:aliceSessionRecord bobSessionRecord:bobSessionRecord];
    [self runInteractionWithAliceRecord:aliceSessionRecord bobRecord:bobSessionRecord];
}

- (void)testBasicSessionCipherDispatchQueue {
    SessionRecord *aliceSessionRecord = [SessionRecord new];
    SessionRecord *bobSessionRecord   = [SessionRecord new];

    XCTestExpectation *expectation = [self expectationWithDescription:@"session cipher completed"];

    dispatch_queue_t sessionCipherDispatchQueue = dispatch_queue_create("session cipher queue", DISPATCH_QUEUE_SERIAL);

    [SessionCipher setSessionCipherDispatchQueue:sessionCipherDispatchQueue];
    dispatch_async(sessionCipherDispatchQueue, ^{
        [self sessionInitializationWithAliceSessionRecord:aliceSessionRecord bobSessionRecord:bobSessionRecord];
        [self runInteractionWithAliceRecord:aliceSessionRecord bobRecord:bobSessionRecord];

        [expectation fulfill];
    });

    [self waitForExpectationsWithTimeout:5.0 handler:^(NSError * _Nullable error) {
        if (error) {
            XCTFail(@"Expectation failed with error: %@", error);
        }
    }];
    [SessionCipher setSessionCipherDispatchQueue:nil];
}

- (void)testPromotingOldSessionState
{
    SessionRecord *aliceSessionRecord = [SessionRecord new];
    SessionRecord *bobSessionRecord = [SessionRecord new];

    // 1.) Given Alice and Bob have initialized some session together
    SessionState *initialSessionState = bobSessionRecord.sessionState;
    [self sessionInitializationWithAliceSessionRecord:aliceSessionRecord bobSessionRecord:bobSessionRecord];

    SessionRecord *activeSession = [self.bobStore loadSession:self.aliceIdentifier deviceId:1];
    XCTAssertNotNil(activeSession);
    XCTAssertEqualObjects(initialSessionState, activeSession.sessionState);

    // 2.) If for some reason, bob has promoted a different session...
    SessionState *newSessionState = [SessionState new];
    [bobSessionRecord promoteState:newSessionState];
    XCTAssertEqual(1, bobSessionRecord.previousSessionStates.count);
    [self.bobStore storeSession:self.aliceIdentifier deviceId:1 session:bobSessionRecord];

    activeSession = [self.bobStore loadSession:self.aliceIdentifier deviceId:1];
    XCTAssertNotNil(activeSession);
    XCTAssertNotEqualObjects(initialSessionState, activeSession.sessionState);
    XCTAssertEqualObjects(newSessionState, activeSession.sessionState);

    // 3.) Bob should promote back the initial session after receiving a message from that old session.
    [self runInteractionWithAliceRecord:aliceSessionRecord bobRecord:bobSessionRecord];
    XCTAssertNotEqualObjects(newSessionState, activeSession.sessionState);
    XCTAssertEqualObjects(initialSessionState, activeSession.sessionState);
    XCTAssertEqual(1, bobSessionRecord.previousSessionStates.count);
    XCTAssertEqual(0, aliceSessionRecord.previousSessionStates.count);
}

- (void)sessionInitializationWithAliceSessionRecord:(SessionRecord *)aliceSessionRecord
                                   bobSessionRecord:(SessionRecord *)bobSessionRecord
{

    SessionState *aliceSessionState = aliceSessionRecord.sessionState;
    SessionState *bobSessionState = bobSessionRecord.sessionState;

    ECKeyPair *aliceIdentityKeyPair = [Curve25519 generateKeyPair];
    ECKeyPair *aliceBaseKey         = [Curve25519 generateKeyPair];
    
    ECKeyPair *bobIdentityKeyPair   = [Curve25519 generateKeyPair];
    ECKeyPair *bobBaseKey           = [Curve25519 generateKeyPair];
    ECKeyPair *bobOneTimePK         = [Curve25519 generateKeyPair];
    
    AliceAxolotlParameters *aliceParams = [[AliceAxolotlParameters alloc] initWithIdentityKey:aliceIdentityKeyPair theirIdentityKey:[bobIdentityKeyPair publicKey] ourBaseKey:aliceBaseKey theirSignedPreKey:[bobBaseKey publicKey] theirOneTimePreKey:[bobOneTimePK publicKey] theirRatchetKey:[bobBaseKey publicKey]];
    
    BobAxolotlParameters   *bobParams = [[BobAxolotlParameters alloc] initWithMyIdentityKeyPair:bobIdentityKeyPair theirIdentityKey:[aliceIdentityKeyPair publicKey] ourSignedPrekey:bobBaseKey ourRatchetKey:bobBaseKey ourOneTimePrekey:bobOneTimePK theirBaseKey:[aliceBaseKey publicKey]];
    
    [RatchetingSession initializeSession:bobSessionState sessionVersion:3 BobParameters:bobParams];
    
    [RatchetingSession initializeSession:aliceSessionState sessionVersion:3 AliceParameters:aliceParams];

    [self.aliceStore storeSession:self.bobIdentifier deviceId:1 session:aliceSessionRecord];
    [self.bobStore storeSession:self.aliceIdentifier deviceId:1 session:bobSessionRecord];

    XCTAssert([aliceSessionState.remoteIdentityKey isEqualToData:bobSessionState.localIdentityKey]);
}

- (void)runInteractionWithAliceRecord:(SessionRecord*)aliceSessionRecord bobRecord:(SessionRecord*)bobSessionRecord {
    SessionCipher *aliceSessionCipher =
        [[SessionCipher alloc] initWithAxolotlStore:self.aliceStore recipientId:self.bobIdentifier deviceId:1];
    SessionCipher *bobSessionCipher =
        [[SessionCipher alloc] initWithAxolotlStore:self.bobStore recipientId:self.aliceIdentifier deviceId:1];

    NSData *alicePlainText     = [@"This is a plaintext message!" dataUsingEncoding:NSUTF8StringEncoding];
    WhisperMessage *cipherText = [aliceSessionCipher encryptMessage:alicePlainText];
    
    NSData *bobPlaintext = [bobSessionCipher decrypt:cipherText];
    
    XCTAssert([bobPlaintext isEqualToData:alicePlainText]);
}

@end
