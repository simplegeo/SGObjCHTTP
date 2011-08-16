//
//  SGHTTPClient.m
//  SGObjCHTTP
//
//  Created by Derek Smith on 8/2/11.
//  Copyright 2011 SimpleGeo. All rights reserved.
//

#import "SGHTTPClient.h"

#import "ASIHTTPRequest.h"
#import "ASIHTTPRequest+OAuth.h"
#import "ASIFormDataRequest.h"
#import "ASIFormDataRequest+OAuth.h"

#import "JSONKit.h"

@interface SGCallback (Private)

#if NS_BLOCKS_AVAILABLE
+ (void)releaseBlocks:(NSArray *)blocks;
#endif

@end

@implementation SGCallback
@synthesize delegate, successMethod, failureMethod;

#if NS_BLOCKS_AVAILABLE
@synthesize successBlock, failureBlock;
#endif

- (id)initWithDelegate:(id)d successMethod:(SEL)sMethod failureMethod:(SEL)fMethod
{
    self = [super init];
    if(self) {
        delegate = d;
        successMethod = sMethod;
        failureMethod = fMethod;
    }
    
    return self;
}

+(SGCallback *) callbackWithDelegate:(id)delegate successMethod:(SEL)successMethod failureMethod:(SEL)failureMethod
{
    return [[[SGCallback alloc] initWithDelegate:delegate successMethod:successMethod failureMethod:failureMethod] autorelease];
}

#if NS_BLOCKS_AVAILABLE
+ (SGCallback *)callbackWithSuccessBlock:(SGSuccessBlock)sBlock failureBlock:(SGFailureBlock)fBlock
{
    return [[[SGCallback alloc] initWithSuccessBlock:sBlock failureBlock:fBlock] autorelease];
}

- (id)initWithSuccessBlock:(SGSuccessBlock)sBlock failureBlock:(SGFailureBlock)fBlock
{
    self = [super init];
    if(self) {
        delegate = nil;
        successBlock = [sBlock copy];
        failureBlock = [fBlock copy];
    }
    
    return self;
}
#endif

- (void)doSuccess:(id)response
{
    if(delegate)
        [delegate performSelector:successMethod withObject:response];

#if NS_BLOCKS_AVAILABLE
    if(successBlock)
       successBlock(response);
#endif
}

- (void)doFailure:(NSError *)error
{
    if(delegate)
        [delegate performSelector:failureMethod withObject:error];
    
#if NS_BLOCKS_AVAILABLE
    if(failureBlock)
        failureBlock(error);
#endif    
}

- (void)dealloc
{
#if NS_BLOCKS_AVAILABLE
	NSMutableArray *blocks = [NSMutableArray array];
	if(successBlock) {
		[blocks addObject:successBlock];
		[successBlock release];
		successBlock = nil;
	}
	if(failureBlock) {
		[blocks addObject:failureBlock];
		[failureBlock release];
		failureBlock = nil;
	}    
    [[self class] performSelectorOnMainThread:@selector(releaseBlocks:) 
                                   withObject:blocks
                                waitUntilDone:[NSThread isMainThread]];
    [super dealloc];
}

+ (void)releaseBlocks:(NSArray *)blocks
{
	// Blocks will be released when this method exits
}
#endif

@end

@interface SGHTTPClient (Private)

- (void)handleRequest:(ASIHTTPRequest *)request failure:(BOOL)failed;

- (NSString *)normalizeRequestParams:(NSDictionary *)params;
- (NSObject *)jsonObjectForResponseData:(NSData *)data;

@end

@implementation SGHTTPClient
@synthesize consumerKey, consumerSecret, accessToken, accessTokenSecret, verifier;

- (id)initWithConsumerKey:(NSString *)key consumerSecret:(NSString *)secret
{
    return [self initWithConsumerKey:key consumerSecret:secret accessToken:nil accessTokenSecret:nil];
}

- (id)initWithAccessToken:(NSString *)token
{
    return [self initWithConsumerKey:nil
                      consumerSecret:nil
                         accessToken:token
                        accessTokenSecret:nil];
}

- (id)initWithConsumerKey:(NSString *)key
           consumerSecret:(NSString *)secret 
              accessToken:(NSString *)tokenKey 
             accessTokenSecret:(NSString *)tokenSecret
{
    self = [super init];
    if(self) {

        if(key)
            consumerKey = [key retain];
        if(secret)
            consumerSecret = [secret retain];
        if(tokenKey)
            accessToken = [tokenKey retain];
        if(tokenSecret)
            accessTokenSecret = [tokenSecret retain];
    }
    
    return self;    
}

////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark ASIHTTPRequest delegate methods 
//////////////////////////////////////////////////////////////////////////////////////////////// 

- (void)requestFinished:(ASIHTTPRequest *)request
{    
    if(200 <= [request responseStatusCode] && [request responseStatusCode] < 300)
        [self handleRequest:request failure:NO];
    else
        [self handleRequest:request failure:YES];
}

- (void)requestFailed:(ASIHTTPRequest *)request
{
    [self handleRequest:request failure:YES];
}

- (void)handleRequest:(ASIHTTPRequest *)request failure:(BOOL)failed
{
    // Every request should contain a callback. If it doesn't,
    // then we are not setup to handle the request.
    NSDictionary* userInfo = [request userInfo];
    if(userInfo) {
        SGCallback *callback = [userInfo objectForKey:@"callback"];
        if(callback) {
            NSObject *response = [self jsonObjectForResponseData:[request responseData]];
            if(failed) {
                if(!response)
                    response = [[[NSString alloc] initWithData:[request responseData] encoding:NSUTF8StringEncoding] autorelease];

                // Add more values to this dictionary in order to provide
                // more error information to the delegate.
                NSDictionary *errorInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                           response, @"response",
                                           nil];
                NSError* error = [NSError errorWithDomain:[request.url absoluteString]
                                                     code:[request responseStatusCode]
                                                 userInfo:errorInfo];

                if(callback && callback.delegate && [callback.delegate respondsToSelector:callback.failureMethod])
                    [callback.delegate performSelector:callback.failureMethod withObject:error];

#if NS_BLOCKS_AVAILABLE
                if(callback.failureBlock)
                    callback.failureBlock(error);
#endif
            } else {
                NSObject *response = [self jsonObjectForResponseData:[request responseData]];
                if(callback && callback.delegate && [callback.delegate respondsToSelector:callback.successMethod])
                    [callback.delegate performSelector:callback.successMethod 
                                            withObject:response];                

#if NS_BLOCKS_AVAILABLE
                if(callback.successBlock)
                    callback.successBlock(response);
#endif
            }   
        }
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark Utility methods
////////////////////////////////////////////////////////////////////////////////////////////////

- (void)sendHTTPRequest:(NSString *)type
                  toURL:(NSURL *)url
             withParams:(id)params 
               callback:(SGCallback *)callback
{	
    // Used in 3-legged oauth2.0
    if(accessToken && !consumerKey && !consumerSecret) {
        url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@%@",
                                    [url absoluteString],
                                    [url query] ? @"&" : @"?",
                                    [self normalizeRequestParams:[NSDictionary dictionaryWithObject:accessToken forKey:@"oauth_token"]]]];
    }
    
    ASIHTTPRequest* request = nil;
    if([type isEqualToString:@"POST"]) {
        ASIFormDataRequest *postRequest = [ASIFormDataRequest requestWithURL:url];
        if([params isKindOfClass:[NSDictionary class]]) {
            for(NSString *key in [[params allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
                [postRequest setPostValue:[params objectForKey:key] forKey:key];
            }
        } else if([params isKindOfClass:[NSData class]])
            [postRequest setPostBody:[NSMutableData dataWithData:params]];

        request = postRequest;
    } else {
        NSString *queryParameters = nil;
        if(params) {
           if([params isKindOfClass:[NSDictionary class]] && [params count]) {
               queryParameters = [NSString stringWithFormat:@"%@%@", 
                                  url.query ? @"&" : @"?",
                                  [self normalizeRequestParams:params]];
               
               url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@", [url absoluteString], queryParameters]];               
           }
        }

        request = [ASIHTTPRequest requestWithURL:url];
        
        if(params && [params isKindOfClass:[NSData class]])
            [request setPostBody:[NSMutableData dataWithData:params]];
    }
    
    request.requestMethod = type;
    if(consumerKey && consumerSecret) {
        [request signRequestWithClientIdentifier:consumerKey
                                          secret:consumerSecret
                                 tokenIdentifier:accessToken
                                          secret:accessTokenSecret
                                        verifier:verifier
                                     usingMethod:ASIOAuthHMAC_SHA1SignatureMethod];
    }
    
    request.userInfo = [NSDictionary dictionaryWithObject:callback forKey:@"callback"];    
    [request setDelegate:self];
    [request addRequestHeader:@"Accept" value:@"application/json"];
    [request startAsynchronous];
}

- (NSObject *)jsonObjectForResponseData:(NSData *)data
{
    NSString *jsonString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSDictionary *jsonObject = nil;
    if(jsonString)
        jsonObject = [jsonString objectFromJSONString];
    [jsonString release];
    return jsonObject;
}

- (NSString *)normalizeRequestParams:(NSDictionary *)params
{
    NSMutableArray *parameterPairs = [NSMutableArray arrayWithCapacity:([params count])];
    id value= nil;
    for(NSString* param in params) {
        value = [params objectForKey:param];
        if([value isKindOfClass:[NSArray class]]) {
            for(NSString *element in value) {
                [parameterPairs addObject:[[NSString stringWithFormat:@"%@=%@", param, element]
                                           stringByAddingPercentEscapesUsingEncoding:NSASCIIStringEncoding]];                
            }
        } else {
            param = [NSString stringWithFormat:@"%@=%@", param, value];
            [parameterPairs addObject:[param stringByAddingPercentEscapesUsingEncoding:NSASCIIStringEncoding]];
        }
    }
    
    NSArray* sortedPairs = [parameterPairs sortedArrayUsingSelector:@selector(compare:)];
    return [sortedPairs componentsJoinedByString:@"&"];
}

- (void) dealloc
{
    [consumerKey release];
    [accessToken release];
    [accessTokenSecret release];
    [consumerSecret release];
    [verifier release];
    [super dealloc];
}

@end
