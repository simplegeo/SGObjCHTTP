//
//  SGASIAuthenticationDialog.h
//  Part of SGASIHTTPRequest -> http://allseeing-i.com/SGASIHTTPRequest
//
//  Created by Ben Copsey on 21/08/2009.
//  Copyright 2009 All-Seeing Interactive. All rights reserved.
//

// !!! NOTE !!!
//
// The content has been modified in order to address
// namespacing issues.
//
// !!! NOTE !!!

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@class SGASIHTTPRequest;

typedef enum _SGASIAuthenticationType {
	SGASIStandardAuthenticationType = 0,
    SGASIProxyAuthenticationType = 1
} SGASIAuthenticationType;

@interface SGASIAutorotatingViewController : UIViewController
@end

@interface SGASIAuthenticationDialog : SGASIAutorotatingViewController <UIActionSheetDelegate, UITableViewDelegate, UITableViewDataSource> {
	SGASIHTTPRequest *request;
	SGASIAuthenticationType type;
	UITableView *tableView;
	UIViewController *presentingController;
	BOOL didEnableRotationNotifications;
}
+ (void)presentAuthenticationDialogForRequest:(SGASIHTTPRequest *)request;
+ (void)dismiss;

@property (retain) SGASIHTTPRequest *request;
@property (assign) SGASIAuthenticationType type;
@property (assign) BOOL didEnableRotationNotifications;
@property (retain, nonatomic) UIViewController *presentingController;
@end
