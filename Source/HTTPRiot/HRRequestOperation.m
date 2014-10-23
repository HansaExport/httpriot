//
//  HRRequestOperation.m
//  HTTPRiot
//
//  Created by Justin Palmer on 1/30/09.
//  Copyright 2009 LabratRevenge LLC.. All rights reserved.
//

#import "HRRequestOperation.h"
#import "HRFormatJSON.h"
#import "HRFormatXML.h"
#import "NSObject+InvocationUtils.h"
#import "NSString+EscapingUtils.h"
#import "NSDictionary+ParamUtils.h"
#import "HRBase64.h"
#import "HROperationQueue.h"
#import "HRRestWeakReferenceContainer.h"

@interface HRRequestOperation (PrivateMethods)
- (NSMutableURLRequest *)http;
- (NSArray *)formattedResults:(NSData *)data;
- (void)setDefaultHeadersForRequest:(NSMutableURLRequest *)request;
- (void)setAuthHeadersForRequest:(NSMutableURLRequest *)request;
- (NSMutableURLRequest *)configuredRequest;
- (id)formatterFromFormat;
- (NSURL *)composedURL;
+ (id)handleResponse:(NSHTTPURLResponse *)response error:(NSError **)error;
+ (NSString *)buildQueryStringFromParams:(NSDictionary *)params;
- (void)finish;
@end

@implementation HRRequestOperation
@synthesize timeout              = _timeout;
@synthesize requestMethod        = _requestMethod;
@synthesize path                 = _path;
@synthesize options              = _options;
@synthesize formatter            = _formatter;
@synthesize delegate             = _delegate;
@synthesize parentViewController = _parentViewController;


- (id)initWithMethod:(HRRequestMethod)method path:(NSString*)urlPath options:(NSDictionary*)opts object:(id)obj {
                 
    if(self = [super init]) {
        _isExecuting    = NO;
        _isFinished     = NO;
        _isCancelled    = NO;
        _requestMethod  = method;
        _path           = [urlPath copy];
        _options        = opts;
        _object         = obj;
        _timeout        = 30.0;
        _delegate       = [[opts valueForKey:kHRClassAttributesDelegateKey] nonretainedObjectValue];
        _formatter      = [self formatterFromFormat];
        
        HRRestWeakReferenceContainer* weakContainer = (HRRestWeakReferenceContainer*) [opts objectForKey:kHRClassParentViewControllerKey];
        NSAssert(weakContainer.weakReference != nil ? [weakContainer.weakReference isKindOfClass:[UIViewController class]] : YES, @"Container contains incorrect class");
        self.parentViewController = (UIViewController*)weakContainer.weakReference;
    }

    return self;
}

////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Concurrent NSOperation Methods
- (void)start {
    // Snow Leopard Fix. See http://www.dribin.org/dave/blog/archives/2009/09/13/snowy_concurrent_operations/
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];
        return;
    }
    
    [self willChangeValueForKey:@"isExecuting"];
    _isExecuting = YES;
    [self didChangeValueForKey:@"isExecuting"];
    
    NSURLRequest *request = [self configuredRequest];
    HRLOG(@"FETCHING:%@ \nHEADERS:%@", [[request URL] absoluteString], [request allHTTPHeaderFields]);
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:YES];
    
    if(_connection) {
        _responseData = [[NSMutableData alloc] init];        
    } else {
        [self finish];
    }    
}

- (void)finish {
    HRLOG(@"Operation Finished. Releasing...");
    _connection = nil;
    
    _responseData = nil;

    [self willChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];

    _isExecuting = NO;
    _isFinished = YES;

    [self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
}

- (void)cancel {
    HRLOG(@"SHOULD CANCEL");
    [self willChangeValueForKey:@"isCancelled"];
    
    [_connection cancel];    
    _isCancelled = YES;
    
    [self didChangeValueForKey:@"isCancelled"];
    
    [self finish];
}

- (BOOL)isExecuting {
   return _isExecuting;
}

- (BOOL)isFinished {
   return _isFinished;
}

- (BOOL)isCancelled {
   return _isCancelled;
}

- (BOOL)isConcurrent {
    return YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSURLConnection delegates
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {    
    HRLOG(@"Server responded with:%li, %@", (long)[response statusCode], [NSHTTPURLResponse localizedStringForStatusCode:[response statusCode]]);
    
    if ([_delegate respondsToSelector:@selector(restConnection:didReceiveResponse:object:)]) {
        [_delegate performSelectorOnMainThread:@selector(restConnection:didReceiveResponse:object:) withObjects:connection, response, _object, nil];
    }
    
    NSError *error = nil;
    [[self class] handleResponse:(NSHTTPURLResponse *)response error:&error];
    
    if(error) {
        if([_delegate respondsToSelector:@selector(restConnection:didReceiveError:response:object:)]) {
            [_delegate performSelectorOnMainThread:@selector(restConnection:didReceiveError:response:object:) withObjects:connection, error, response, _object, nil];
            [connection cancel];
            [self finish];
        }
    }
    
    [_responseData setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {   
    [_responseData appendData:data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {  
    HRLOG(@"Connection failed: %@", [error localizedDescription]);
    if([_delegate respondsToSelector:@selector(restConnection:didFailWithError:object:)]) {        
        [_delegate performSelectorOnMainThread:@selector(restConnection:didFailWithError:object:) withObjects:connection, error, _object, nil];
    }
    
    [self finish];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {    
    id results = [NSNull null];
    NSError *parseError = nil;
    if([_responseData length] > 0) {
        results = [[self formatter] decode:_responseData error:&parseError];
                
        if(parseError) {
            NSString *rawString = [[NSString alloc] initWithData:_responseData encoding:NSUTF8StringEncoding];
            if([_delegate respondsToSelector:@selector(restConnection:didReceiveParseError:responseBody:object:)]) {
                [_delegate performSelectorOnMainThread:@selector(restConnection:didReceiveParseError:responseBody:object:) withObjects:connection, parseError, rawString, _object, nil];                
            }
            
            [self finish];
            
            return;
        }  
    }

    if([_delegate respondsToSelector:@selector(restConnection:didReturnResource:object:)]) {        
        [_delegate performSelectorOnMainThread:@selector(restConnection:didReturnResource:object:) withObjects:connection, results, _object, nil];
    }
        
    [self finish];
}

// A delegate method called by the NSURLConnection when something happens with the 
// connection security-wise.  We defer all of the logic for how to handle this to 
// the ChallengeHandler module (and it's very custom subclasses).
- (BOOL)connection:(NSURLConnection *)conn canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace
{
#pragma unused(conn)
    BOOL    result;
    
    assert( conn == _connection );
    assert( protectionSpace != nil );
    
    result = [HRChallengeHandler supportsProtectionSpace:protectionSpace];
    HRLOG(@"canAuthenticateAgainstProtectionSpace %@ -> %d", [protectionSpace authenticationMethod], result);
    return result;
}

// A delegate method called by the NSURLConnection when you accept a specific 
// authentication challenge by returning YES from -connection:canAuthenticateAgainstProtectionSpace:. 
// Again, most of the logic has been shuffled off to the ChallengeHandler module; the only 
// policy decision we make here is that, if the challenge handle doesn't get it right in 5 tries, 
// we bail out.
- (void)connection:(NSURLConnection *)conn didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
#pragma unused(conn)
    assert( conn == _connection );
    assert( challenge != nil );
    
    HRLOG(@"didReceiveAuthenticationChallenge %@ %zd", [[challenge protectionSpace] authenticationMethod], (ssize_t) [challenge previousFailureCount]);
    
    assert( _currentChallenge == nil );
    assert( self.parentViewController != nil );
    
    // If not in debug mode: Provide warning if no view controller is available
    if ( !self.parentViewController )
    {
    	NSLog( @"WARNING: No parent view controller is set. Now cancel authentication requests which may need a view" );
        [[challenge sender] cancelAuthenticationChallenge:challenge];
        return;
    }
    
    if ( [challenge previousFailureCount] < 5 
        && self.parentViewController )
    {
        _currentChallenge = [HRChallengeHandler handlerForChallenge:challenge parentViewController:self.parentViewController];
        if (_currentChallenge == nil) {
            [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
        } else {
            _currentChallenge.delegate = self;
            [_currentChallenge start];
        }
    } else {
        [[challenge sender] cancelAuthenticationChallenge:challenge];
    }
}


////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Configuration

- (void)setDefaultHeadersForRequest:(NSMutableURLRequest *)request {
    NSDictionary *headers = [[self options] valueForKey:kHRClassAttributesHeadersKey];
    [request setValue:[[self formatter] mimeType] forHTTPHeaderField:@"Content-Type"];  
    [request addValue:[[self formatter] mimeType] forHTTPHeaderField:@"Accept"];
    if(headers) {
        for(NSString *header in headers) {
            NSString *value = [headers valueForKey:header];
            if([header isEqualToString:@"Accept"]) {
                [request addValue:value forHTTPHeaderField:header];
            } else {
                [request setValue:value forHTTPHeaderField:header];
            }
        }        
    }
}

- (void)setAuthHeadersForRequest:(NSMutableURLRequest *)request {
    NSDictionary *authDict = [_options valueForKey:kHRClassAttributesBasicAuthKey];
    NSString *username = [authDict valueForKey:kHRClassAttributesUsernameKey];
    NSString *password = [authDict valueForKey:kHRClassAttributesPasswordKey];
    
    if(username || password) {
        NSString *userPass = [NSString stringWithFormat:@"%@:%@", username, password];
        NSData   *upData = [userPass dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUserPass = [HRBase64 encode:upData];
        NSString *basicHeader = [NSString stringWithFormat:@"Basic %@", encodedUserPass];
        [request setValue:basicHeader forHTTPHeaderField:@"Authorization"];
    }
}

- (NSMutableURLRequest *)configuredRequest
{
    NSMutableURLRequest * request = [[NSMutableURLRequest alloc] init];
    [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
    [request setTimeoutInterval:_timeout];
    [request setHTTPShouldHandleCookies:YES];
    [self setDefaultHeadersForRequest:request];
    [self setAuthHeadersForRequest:request];
    
    NSURL * composedURL = [self composedURL];
    NSDictionary * params = [[self options] valueForKey:kHRClassAttributesParamsKey];
    id body = [[self options] valueForKey:kHRClassAttributesBodyKey];
    
    NSString * queryString = @"";
    if ([[self class] buildQueryStringFromParams:params] != nil)
    { queryString = [[self class] buildQueryStringFromParams:params]; }
    
    if ([[self options] valueForKey:kHRClassAttributesUsingBodyAndUrlKey] != nil && [[[self options] valueForKey:kHRClassAttributesUsingBodyAndUrlKey] boolValue] == YES)
    {
        if (_requestMethod == HRRequestMethodGet ||
            _requestMethod == HRRequestMethodDelete ||
            _requestMethod == HRRequestMethodPost ||
            _requestMethod == HRRequestMethodPut)
        {
            NSString * urlString = [[composedURL absoluteString] stringByAppendingString:queryString];
            NSURL * url = [NSURL URLWithString:urlString];
            [request setURL:url];
            
            NSData * bodyData = nil;
            if ([body isKindOfClass:[NSDictionary class]])
            { bodyData = [[body toQueryString] dataUsingEncoding:NSUTF8StringEncoding]; }
            else if ([body isKindOfClass:[NSString class]])
            { bodyData = [body dataUsingEncoding:NSUTF8StringEncoding]; }
            else if ([body isKindOfClass:[NSData class]])
            { bodyData = body; }
            else if (body != nil)
            {
                [NSException exceptionWithName:@"InvalidBodyData"
                                        reason:@"The body must be an NSDictionary, NSString, or NSData"
                                      userInfo:nil];
            }
            
            if (bodyData != nil)
            { [request setHTTPBody:bodyData]; }
            
            if (_requestMethod == HRRequestMethodGet)
            { [request setHTTPMethod:@"GET"]; }
            else if (_requestMethod == HRRequestMethodDelete)
            { [request setHTTPMethod:@"DELETE"]; }
            else if (_requestMethod == HRRequestMethodPost)
            { [request setHTTPMethod:@"POST"]; }
            else if (_requestMethod == HRRequestMethodPut)
            { [request setHTTPMethod:@"PUT"]; }
        }
    }
    // Default Behaviour :-)
    else
    {
        if (_requestMethod == HRRequestMethodGet ||
            _requestMethod == HRRequestMethodDelete)
        {
            NSString * urlString = [[composedURL absoluteString] stringByAppendingString:queryString];
            NSURL * url = [NSURL URLWithString:urlString];
            [request setURL:url];
            
            if (_requestMethod == HRRequestMethodGet)
            { [request setHTTPMethod:@"GET"]; }
            else
            { [request setHTTPMethod:@"DELETE"]; }
        }
        else if (_requestMethod == HRRequestMethodPost ||
                 _requestMethod == HRRequestMethodPut)
        {
            NSData * bodyData = nil;
            
            if ([body isKindOfClass:[NSDictionary class]])
            { bodyData = [[body toQueryString] dataUsingEncoding:NSUTF8StringEncoding]; }
            else if([body isKindOfClass:[NSString class]])
            { bodyData = [body dataUsingEncoding:NSUTF8StringEncoding]; }
            else if([body isKindOfClass:[NSData class]])
            { bodyData = body; }
            else
            {
                [NSException exceptionWithName:@"InvalidBodyData"
                                        reason:@"The body must be an NSDictionary, NSString, or NSData"
                                      userInfo:nil];
            }
            
            [request setHTTPBody:bodyData];
            [request setURL:composedURL];
            
            if (_requestMethod == HRRequestMethodPost)
            { [request setHTTPMethod:@"POST"]; }
            else
            { [request setHTTPMethod:@"PUT"]; }
        }
    }
    
    return request;
}

- (NSURL *)composedURL {
    NSURL *tmpURI = [NSURL URLWithString:_path];
    NSURL *baseURL = [_options objectForKey:kHRClassAttributesBaseURLKey];

    if([tmpURI host] == nil && [baseURL host] == nil)
        [NSException raise:@"UnspecifiedHost" format:@"host wasn't provided in baseURL or path"];
    
    if([tmpURI host])
        return tmpURI;
        
    return [NSURL URLWithString:[[baseURL absoluteString] stringByAppendingPathComponent:_path]];
}

- (id)formatterFromFormat {
    NSNumber *format = [[self options] objectForKey:kHRClassAttributesFormatKey];
    id theFormatter = nil;
    switch([format intValue]) {
        case HRDataFormatJSON:
            theFormatter = [HRFormatJSON class];
        break;
        case HRDataFormatXML:
            theFormatter = [HRFormatXML class];
        break;
        default:
            theFormatter = [HRFormatJSON class];
        break;   
    }
    
    NSString *errorMessage = [NSString stringWithFormat:@"Invalid Formatter %@", NSStringFromClass(theFormatter)];
    NSAssert([theFormatter conformsToProtocol:@protocol(HRFormatterProtocol)], errorMessage); 
    
    return theFormatter;
}

////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Class Methods
+ (HRRequestOperation *)requestWithMethod:(HRRequestMethod)method path:(NSString*)urlPath options:(NSDictionary*)requestOptions object:(id)obj {
    HRRequestOperation* operation = [[self alloc] initWithMethod:method path:urlPath options:requestOptions object:obj];
    [[HROperationQueue sharedOperationQueue] addOperation:operation];
    return operation;
}

+ (id)handleResponse:(NSHTTPURLResponse *)response error:(NSError **)error {
    NSInteger code = [response statusCode];
    NSUInteger ucode = [[NSNumber numberWithInteger:code] unsignedIntValue];
    NSRange okRange = NSMakeRange(200, 201);
    
    if(NSLocationInRange(ucode, okRange)) {
        return response;
    }

    if(error != nil) {
        NSDictionary *headers = [response allHeaderFields];
        NSString *errorReason = [NSString stringWithFormat:@"%ld Error: ", (long)code];
        NSString *errorDescription = [NSHTTPURLResponse localizedStringForStatusCode:code];
        NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                   errorReason, NSLocalizedFailureReasonErrorKey,
                                   errorDescription, NSLocalizedDescriptionKey, 
                                   headers, kHRClassAttributesHeadersKey, 
                                   [[response URL] absoluteString], @"url", nil];
        *error = [NSError errorWithDomain:HTTPRiotErrorDomain code:code userInfo:userInfo];
    }

    return nil;
}

+ (NSString *)buildQueryStringFromParams:(NSDictionary *)theParams {
    if(theParams) {
        if([theParams count] > 0)
            return [NSString stringWithFormat:@"?%@", [theParams toQueryString]];
    }
    
    return @"";
}

#pragma mark * Authentication challenge UI
// Called by the authentication challenge handler once the challenge is 
// resolved.  We twiddle our internal state and then call the -resolve method 
// to apply the challenge results to the NSURLAuthenticationChallenge.
- (void)challengeHandlerDidFinish:(HRChallengeHandler *)handler
{
#pragma unused(handler)
    HRChallengeHandler *  challenge;
    
    assert(handler == _currentChallenge);
    
    // We want to nil out currentChallenge because we've really done with this 
    // challenge now and, for example, if the next operation kicks up a new 
    // challenge, we want to make sure that currentChallenge is ready to receive 
    // it.
    // 
    // We want the challenge to hang around after we've nilled out currentChallenge, 
    // so retain/autorelease it.
    
    challenge = _currentChallenge;
    _currentChallenge = nil;
    
    // If the credential isn't present, this will trigger a -connection:didFailWithError: 
    // callback.
    
    HRLOG(@"resolve %@ -> %@", [[challenge.challenge protectionSpace] authenticationMethod], challenge.credential);
    [challenge resolve];
}

@end
