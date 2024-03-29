/*
    File:       RetryingHTTPOperation.m
    Contains:   Runs an HTTP request, with support for retries.
*/

#import "RetryingHTTPOperation.h"
#import "NetworkManager.h"
#import "Logging.h"
#import "QHTTPOperation.h"
#import "QReachabilityOperation.h"
/*
// When one operation completes it posts the following notification.  Other operations 
// listen for that notification and, if the host name matches, expedite their retry. 
// This means that, if one request succeeds, subsequent requests will retry quickly.
*/
static NSString * kRetryingHTTPOperationTransferDidSucceedNotification = @"com.apple.dts.kRetryingHTTPOperationTransferDidSucceedNotification";
static NSString * kRetryingHTTPOperationTransferDidSucceedHostKey = @"hostName";




@interface RetryingHTTPOperation ()

// read/write versions of public properties
@property (assign, readwrite) RetryingHTTPOperationState    retryState;
@property (assign, readwrite) RetryingHTTPOperationState    retryStateClient;
@property (assign, readwrite) BOOL                          hasHadRetryableFailure;
@property (assign, readwrite) NSUInteger                    retryCount;
@property (copy,   readwrite) NSData *                      responseContent;   

// private properties
@property (copy,   readwrite) NSHTTPURLResponse *           response;
@property (retain, readwrite) QHTTPOperation *              networkOperation;
@property (retain, readwrite) NSTimer *                     retryTimer;
@property (retain, readwrite) QReachabilityOperation *      reachabilityOperation;
@property (assign, readwrite) BOOL                          notificationInstalled;

// forward declaration
- (void)startRequest;
- (void)startReachabilityReachable:(BOOL)reachable;
- (void)startRetryAfterTimeInterval:(NSTimeInterval)delay;

@end




@implementation RetryingHTTPOperation

// See comment in header.
- (id)initWithRequest:(NSURLRequest *)request{
    assert(request != nil);
    
    // Certain HTTP methods are idempotent, meaning that doing the request N times is 
    // equivalent to doing it once.  As this class will automatically retry the request, 
    // the requests method should be idempotent lest the automatic retries cause problems. 
    // For example, you could imagine a situation where an automatically retried POST might 
    // cause a gazillion identical messages to show up on a bulletin board well site.
    
    #if ! defined(NDEBUG)
        static NSSet * sIdempotentHTTPMethods;
        
        if (sIdempotentHTTPMethods == nil) {
            @synchronized ([self class]) {
                if (sIdempotentHTTPMethods == nil) {
                    sIdempotentHTTPMethods = [[NSSet alloc] initWithObjects:@"GET", @"HEAD", @"PUT", @"DELETE", @"OPTIONS", @"TRACE", nil];
                }
            }
        }
        assert([sIdempotentHTTPMethods containsObject:[request HTTPMethod]]);
    #endif

    self = [super init];
    if (self != nil) {
        @synchronized ([self class]) {
            static NSUInteger sSequenceNumber;
            self->_sequenceNumber = sSequenceNumber;
            sSequenceNumber += 1;
        }
        self->_request = [request copy];
        assert(self->_retryState       == kRetryingHTTPOperationStateNotStarted);
    }
    return self;
}

- (void)dealloc{
    [self->_request release];
    [self->_acceptableContentTypes release];
    [self->_responseFilePath release];
    [self->_response release];
    [self->_responseContent release];
    assert(self->_networkOperation == nil);
    assert(self->_retryTimer == nil);
    assert(self->_reachabilityOperation == nil);
    [super dealloc];
}



#pragma mark * Properties

@synthesize request                = _request;

- (RetryingHTTPOperationState)retryState{
    return self->_retryState;
}

// We don't really need this custom setter, but it's a great way to flush  out redundant update problems.
- (void)setRetryState:(RetryingHTTPOperationState)newValue{
    assert([self isActualRunLoopThread]);
    assert(newValue != self->_retryState);
    self->_retryState = newValue;
    
    [self performSelectorOnMainThread:@selector(syncRetryStateClient) withObject:nil waitUntilDone:NO];
}

@synthesize retryStateClient       = retryStateClient;

// Sets the retryStateClient property on the main thread.
- (void)syncRetryStateClient{
    assert([NSThread isMainThread]);
    self.retryStateClient = self.retryState;
}

@synthesize hasHadRetryableFailure = _hasHadRetryableFailure;
@synthesize acceptableContentTypes = _acceptableContentTypes;
@synthesize responseFilePath       = _responseFilePath;
@synthesize response               = _response;
@synthesize networkOperation       = _networkOperation;
@synthesize retryTimer             = _retryTimer;
@synthesize retryCount             = _retryCount;
@synthesize reachabilityOperation  = _reachabilityOperation;
@synthesize notificationInstalled  = _notificationInstalled;

// See comment in header.
- (NSString *)responseMIMEType{
    NSString *          result;
    NSHTTPURLResponse * response;
    
    result = nil;
    response = self.response;
    if (response != nil) {
        result = [response MIMEType];
    }
    return result;
}

@synthesize responseContent = _responseContent;



#pragma mark * Utilities

// Sets the hasHadRetryableFailure on the main thread.
- (void)setHasHadRetryableFailureOnMainThread{
    assert([NSThread isMainThread]);
    assert( ! self.hasHadRetryableFailure );
    self.hasHadRetryableFailure = YES;
}

// Returns YES if the supplied error is fatal, that is, it can't be  meaningfully retried.
- (BOOL)shouldRetryAfterError:(NSError *)error{
    BOOL    shouldRetry;
    
    if ( [[error domain] isEqual:kQHTTPOperationErrorDomain] ) {
    
        // We can easily understand the consequence of coming directly from 
        // QHTTPOperation.
        
        if ( [error code] > 0 ) {
            // The request made it to the server, which failed it.  We consider that to be 
            // fatal.  It might make sense to handle error 503 "Service Unavailable" as a 
            // special case here but, realistically, how common is that?
            shouldRetry = NO;
        } else {
            switch ( [error code] ) {
                default:
                    assert(NO);     // what is this error?
                    // fall through
                case kQHTTPOperationErrorResponseTooLarge:
                case kQHTTPOperationErrorOnOutputStream:
                case kQHTTPOperationErrorBadContentType: {
                    shouldRetry = NO;   // all of these conditions are unlikely to fail
                } break;
            }
        }
    } else {

        // We treat all other errors are retryable.  Most errors are likely to be from 
        // the network, and that's exactly what we want to retry.  Clearly this is going to 
        // need some refinement based on real world experience.
    
        shouldRetry = YES;
    }
    return shouldRetry;
}

/*
// This isn't a crypto system, so we don't care about mod bias, so we just calculate 
// the random time interval by taking the random number, mod'ing it by the number 
// of milliseconds of the delay range, and then converting that number of milliseconds 
// to an NSTimeInterval.
*/

// Helper method for -shortRetryDelay and -randomRetryDelay.
- (NSTimeInterval)retryDelayWithinRangeAtIndex:(NSUInteger)rangeIndex{
    // First retry is after one second; next retry is after one minute; next retry 
    // is after one hour; next retry (and all subsequent retries) is after six hours.
    static const NSUInteger kRetryDelays[] = { 1, 60, 60 * 60, 6 * 60 * 60 };

    if (rangeIndex >= (sizeof(kRetryDelays) / sizeof(kRetryDelays[0]))) {
        rangeIndex = (sizeof(kRetryDelays) / sizeof(kRetryDelays[0])) - 1;
    }
    return ((NSTimeInterval) (((NSUInteger) arc4random()) % (kRetryDelays[rangeIndex] * 1000))) / 1000.0;
}

// Returns a random short delay (that is, within the next second).
- (NSTimeInterval)shortRetryDelay{
    return [self retryDelayWithinRangeAtIndex:0];
}

/*
 // Returns a random delay that's based on the retryCount; the delay range grows 
 // rapidly with the number of retries, thereby ensuring that we don't continuously 
 // thrash the device doing unsuccessful retries. 
 */
- (NSTimeInterval)randomRetryDelay{
    return [self retryDelayWithinRangeAtIndex:self.retryCount];
}




#pragma mark * Core state transitions

// Called by QRunLoopOperation when the operation starts.  We just kick off the  initial HTTP request.
- (void)operationDidStart{
    assert([self isActualRunLoopThread]);
    assert(self.retryState == kRetryingHTTPOperationStateNotStarted);

    [super operationDidStart];
    
    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu start %@", (size_t) self->_sequenceNumber, [self.request URL]];

    self.retryState = kRetryingHTTPOperationStateGetting;
    [self startRequest];
}

// Starts the HTTP request.  This might be the first request or a retry.
- (void)startRequest{
    assert([self isActualRunLoopThread]);
    assert( (self.retryState == kRetryingHTTPOperationStateGetting) || (self.retryState == kRetryingHTTPOperationStateRetrying) );
    assert(self.networkOperation == nil);

    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu request start", (size_t) self->_sequenceNumber];
    
    // Create the network operation.
    
    self.networkOperation = [[[QHTTPOperation alloc] initWithRequest:self.request] autorelease];
    assert(self.networkOperation != nil);
    
    // Copy our properties over to the network operation.
    
    [self.networkOperation setQueuePriority:[self queuePriority]];
    self.networkOperation.acceptableContentTypes = self.acceptableContentTypes;
    self.networkOperation.runLoopThread = self.runLoopThread;
    self.networkOperation.runLoopModes  = self.runLoopModes;
    
    // If we're downloading to a file, set up an output stream that points to that file. 
    // 
    // Note that we pass NO to the append parameter; if we wanted to support resumeable 
    // downloads, we could do it here (but we'd have to mess around with etags and so on).
    
    if (self.responseFilePath != nil) {
        self.networkOperation.responseOutputStream = [NSOutputStream outputStreamToFileAtPath:self.responseFilePath append:NO];
        assert(self.networkOperation.responseOutputStream != nil);
    }
    
    [[NetworkManager sharedManager] addNetworkTransferOperation:self.networkOperation finishedTarget:self action:@selector(networkOperationDone:)];
}

// Called when the network operation finishes.  We look at the error to decide how to proceed.
- (void)networkOperationDone:(QHTTPOperation *)operation{
    assert([self isActualRunLoopThread]);
    assert( (self.retryState == kRetryingHTTPOperationStateGetting) || (self.retryState == kRetryingHTTPOperationStateRetrying) );
    assert(operation == self.networkOperation);
    self.networkOperation = nil;

    if (operation.error == nil) {
    
        // The request was successful; let's complete the operation.
        
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu request success", (size_t) self->_sequenceNumber];
    
        self.response = operation.lastResponse;
        self.responseContent = operation.responseBody;
        
        [self finishWithError:nil];     // this changes state to kRetryingHTTPOperationStateFinished

    } else {

        // Something went wrong.  Deal with the error.
        
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu request error %@", (size_t) self->_sequenceNumber, operation.error];
    
        if ( ! [self shouldRetryAfterError:operation.error] ) {
            
            // If the error is fatal, we just fail the overall operation.
            
            [self finishWithError:operation.error];
        } else {
        
            // If this is our first retry, tell our client that we are in retry mode.
            
            if (self.retryState == kRetryingHTTPOperationStateGetting) {
                [self performSelectorOnMainThread:@selector(setHasHadRetryableFailureOnMainThread) withObject:nil waitUntilDone:NO];
            }

            // If our notification callback isn't installed, install it.
            //
            // This notification is broadcast if any download succeeds.  If it fires, we 
            // trigger a very quick retry because, if one transfer succeeds, it's likely that 
            // other transfers will succeed as well.

            if ( ! self.notificationInstalled ) {
                [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(transferDidSucceed:) name:kRetryingHTTPOperationTransferDidSucceedNotification object:nil];
                self.notificationInstalled = YES;
            }
            
            // If the reachability operation is not running (this can happen the first time we fail 
            // and if a subsequent reachability-based retry fails), start it up.  Given that reachability 
            // only tells us about the state of our local machine, the operation could have failed for 
            // reasons that reachability knows nothing about.  So before we use a reachability 
            // check to trigger a retry, we want to make sure that the host is first /unreachable/, 
            // and then wait for it to become reachability.  So, let's start with that first part.
            
            if (self.reachabilityOperation == nil) {
                [self startReachabilityReachable:NO];
            }
        
            // Start a time-based retry.
        
            self.retryState = kRetryingHTTPOperationStateWaitingToRetry;
            [self startRetryAfterTimeInterval:[self randomRetryDelay]];
        }
    }
}

/*
 // Called when kRetryingHTTPOperationTransferDidSucceedNotification is posted. 
 // We see if this notification is relevant to us and, if so, pass it on to code 
 // running on our run loop.
 */
- (void)transferDidSucceed:(NSNotification *)note{
    // Can't look at state at this point, but it is safe to look at request because 
    // that's immutable.

    assert( [[note name] isEqual:kRetryingHTTPOperationTransferDidSucceedNotification] );
    assert( [[[note userInfo] objectForKey:kRetryingHTTPOperationTransferDidSucceedHostKey] isKindOfClass:[NSString class]] );

    // If the successful transfer was to /our/ host, we pass the notification off to 
    // our run loop thread.
    
    if ( [[[note userInfo] objectForKey:kRetryingHTTPOperationTransferDidSucceedHostKey] isEqual:[[self.request URL] host]] ) {

        // This raises the question of what happens if the operation changes state (most critically, 
        // if it finishes) while waiting for this selector to be performed.  It turns out that's OK. 
        // The perform will retain self while it's in flight, and if it is delivered in an inappropriate 
        // context (after, say, the operation has finished), it will be ignored based on the retryState.
        
        [self performSelector:@selector(transferDidSucceedOnRunLoopThread) onThread:self.actualRunLoopThread withObject:nil waitUntilDone:NO];
    }
}

// Called on our run loop when a kRetryingHTTPOperationTransferDidSucceedNotification  notification relevant to us is posted.  We check whether a fast retry is in order.
- (void)transferDidSucceedOnRunLoopThread{
    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu other transfer succeeeded", (size_t) self->_sequenceNumber];

    // If some other transfer to the same host succeeded, radically reduce our retry delay.
    
    if (self.retryState == kRetryingHTTPOperationStateWaitingToRetry) {
        assert(self.retryTimer != nil);
        [self.retryTimer invalidate];
        self.retryTimer = nil;
        
        [self startRetryAfterTimeInterval:[self shortRetryDelay]];
    }
}

// Schedules a retry to occur after the specified delay.
- (void)startRetryAfterTimeInterval:(NSTimeInterval)delay{
    assert(self.retryState == kRetryingHTTPOperationStateWaitingToRetry);
    assert(self.retryTimer == nil);

    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu retry wait start %.3f", (size_t) self->_sequenceNumber, delay];

    self.retryTimer = [NSTimer timerWithTimeInterval:delay target:self selector:@selector(retryTimerDone:) userInfo:nil repeats:NO];
    assert(self.retryTimer != nil);
    for (NSString * mode in self.actualRunLoopModes) {
        [[NSRunLoop currentRunLoop] addTimer:self.retryTimer forMode:mode];
    }
}

// Called when the retry timer expires.  It just starts the actual retry.
- (void)retryTimerDone:(NSTimer *)timer{
    assert([self isActualRunLoopThread]);
    assert(timer == self.retryTimer);
    #pragma unused(timer)

    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu retry wait done", (size_t) self->_sequenceNumber];

    [self.retryTimer invalidate];
    self.retryTimer = nil;
    
    assert(self.retryState == kRetryingHTTPOperationStateWaitingToRetry);
    self.retryState = kRetryingHTTPOperationStateRetrying;
    self.retryCount += 1;
    [self startRequest];
}

// Starts a reachability operation waiting for the host associated with this request 
// to become unreachable or reachabel (depending on the "reachable" parameter).
- (void)startReachabilityReachable:(BOOL)reachable{
    [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu %sreachable start", (size_t) self->_sequenceNumber, reachable ? "" : "un" ];

    assert(self.reachabilityOperation == nil);
    self.reachabilityOperation = [[[QReachabilityOperation alloc] initWithHostName:[[self.request URL] host]] autorelease];
    assert(self.reachabilityOperation != nil);

    // In the reachable case the default mask and value is fine.  In the unreachable case 
    // we have to customise them.
    
    if ( ! reachable ) {
        self.reachabilityOperation.flagsTargetMask  = kSCNetworkReachabilityFlagsReachable;
        self.reachabilityOperation.flagsTargetValue = 0;
    }

    [self.reachabilityOperation setQueuePriority:[self queuePriority]];
    self.reachabilityOperation.runLoopThread = self.runLoopThread;
    self.reachabilityOperation.runLoopModes  = self.runLoopModes;

    [[NetworkManager sharedManager] addNetworkManagementOperation:self.reachabilityOperation finishedTarget:self action:@selector(reachabilityOperationDone:)];
}

/*
 // Called when the reachability operation finishes.  If we were looking for the 
 // host to become unreachable, we respond by scheduling a new operation waiting 
 // for the host to become reachable.  OTOH, if we've found that the host has 
 // become reachable (and this must be a transition because we only schedule 
 // such an operation if the host is current unreachable), we force a fast retry.
 */
- (void)reachabilityOperationDone:(QReachabilityOperation *)operation{
    assert([self isActualRunLoopThread]);
    assert(self.retryState >= kRetryingHTTPOperationStateWaitingToRetry);
    assert(operation == self.reachabilityOperation);
    self.reachabilityOperation = nil;
    
    assert(operation.error == nil);     // ReachabilityOperation can never actually fail

    if ( ! (operation.flags & kSCNetworkReachabilityFlagsReachable) ) {
    
        // We've know that the host is not unreachable.  Schedule a reachability operation to 
        // wait for it to become reachable.
    
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu unreachable done (0x%zx)", (size_t) self->_sequenceNumber, (size_t) operation.flags];

        [self startReachabilityReachable:YES];
    } else {
    
        // Reachability has flipped from being unreachable to being reachable.  We respond by 
        // radically shortening the retry delay (although not too short, we want to give the 
        // system time to settle after the reachability change).
        
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu reachable done (0x%zx)", (size_t) self->_sequenceNumber, (size_t) operation.flags];

        if (self.retryState == kRetryingHTTPOperationStateWaitingToRetry) {
            assert(self.retryTimer != nil);
            [self.retryTimer invalidate];
            self.retryTimer = nil;
            
            [self startRetryAfterTimeInterval:[self shortRetryDelay] + 3.0];
        }
    }
}

// Called by QRunLoopOperation when the operation finishes.  We just clean up  our various operations and callbacks.
- (void)operationWillFinish{
    assert([self isActualRunLoopThread]);

    [super operationWillFinish];
    
    if (self.networkOperation != nil) {
        [[NetworkManager sharedManager] cancelOperation:self.networkOperation];
        self.networkOperation = nil;
    }
    if (self.retryTimer != nil) {
        [self.retryTimer invalidate];
        self.retryTimer = nil;
    }
    if (self.reachabilityOperation != nil) {
        [[NetworkManager sharedManager] cancelOperation:self.reachabilityOperation];
        self.reachabilityOperation = nil;
    }
    if (self.notificationInstalled) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:kRetryingHTTPOperationTransferDidSucceedNotification object:nil];
        self.notificationInstalled = NO;
    }
    self.retryState = kRetryingHTTPOperationStateFinished;

    if (self.error == nil) {
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu success", (size_t) self->_sequenceNumber];
        
        // We were successful.  Broadcast a notification to that effect so that other transfers who 
        // are delayed waiting to retry know that now is a good time.
        
        [[NSNotificationCenter defaultCenter] postNotificationName:kRetryingHTTPOperationTransferDidSucceedNotification 
            object:nil 
            userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[[self.request URL] host], kRetryingHTTPOperationTransferDidSucceedHostKey, nil]
        ];//Creates a notification with a given name, sender, and information and posts it to the receiver.
    } else {
        [[QLog log] logOption:kLogOptionNetworkDetails withFormat:@"http %zu error %@", (size_t) self->_sequenceNumber, self.error];
    }
}

@end
