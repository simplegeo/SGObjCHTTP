//
//  SGCallback.m
//  SGObjCHTTP
//
//  Created by Derek Smith on 8/24/11.
//  Copyright 2011 SimpleGeo. All rights reserved.
//

#import "SGCallback.h"

#import "SGJSONKit.h"
#import "SGASIHTTPRequest.h"
#import "SGASIHTTPRequest+OAuth.h"
#import "SGASIFormDataRequest+OAuth.h"

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
