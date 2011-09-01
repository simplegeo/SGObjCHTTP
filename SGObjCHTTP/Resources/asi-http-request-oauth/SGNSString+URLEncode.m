//
//  NSString+URLEncode.m
//
//  Created by Scott James Remnant on 6/1/11.
//  Copyright 2011 Scott James Remnant <scott@netsplit.com>. All rights reserved.
//

// !!! NOTE !!!
//
// The content has been modified in order to address
// namespacing issues.
//
// !!! NOTE !!!

#import "SGNSString+URLEncode.h"

#define LEGAL_CHARS "!*'();:@&=+$,/?#[]<>\"{}|\\`^% "

@implementation NSString (SGNSString_URLEncode)

- (NSString *)encodeForURL
{
    return NSMakeCollectable(CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (CFStringRef)self, NULL, CFSTR(LEGAL_CHARS), kCFStringEncodingUTF8));
}

- (NSString *)encodeForURLReplacingSpacesWithPlus;
{
    NSString *replaced = [self stringByReplacingOccurrencesOfString:@" " withString:@"+"];
    return NSMakeCollectable(CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (CFStringRef)replaced, NULL, CFSTR(LEGAL_CHARS), kCFStringEncodingUTF8));
}

- (NSString *)decodeFromURL
{
    NSString *decoded = NSMakeCollectable(CFURLCreateStringByReplacingPercentEscapesUsingEncoding(kCFAllocatorDefault, (CFStringRef)self, CFSTR(""), kCFStringEncodingUTF8));
    return [decoded stringByReplacingOccurrencesOfString:@"+" withString:@" "];
}

@end
