//
//  SGASIFormDataRequest+OAuth.m
//
//  Created by Scott James Remnant on 6/3/11.
//  Copyright 2011 Scott James Remnant <scott@netsplit.com>. All rights reserved.
//

// !!! NOTE !!!
//
// The content has been modified in order to address
// namespacing issues.
//
// !!! NOTE !!!

#import "SGASIFormDataRequest+OAuth.h"


@implementation SGASIFormDataRequest (SGASIFormDataRequest_OAuth)

- (NSArray *)oauthPostBodyParameters
{
	if ([fileData count] > 0)
        return nil;

    return postData;
}

@end
