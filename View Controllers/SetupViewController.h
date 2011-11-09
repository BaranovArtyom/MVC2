/*
    File:       SetupViewController.h
    Contains:   Lets the user configure the gallery to view.
*/

#import <UIKit/UIKit.h>

@protocol SetupViewControllerDelegate;


@interface SetupViewController : UITableViewController
{
    id<SetupViewControllerDelegate>     _delegate;
    NSMutableArray *                    _choices;
    BOOL                                _choicesDirty;
    NSUInteger                          _choiceIndex;
    NSString *                          _otherChoice;
    UITextField *                       _activeTextField;
}

// Resets the list of choices back to their default values.  Called on application  startup if the user enables the appropriate setting.
+ (void)resetChoices;

// galleryURLString may be nil, implying that no gallery is currently selected.
- (id)initWithGalleryURLString:(NSString *)galleryURLString;

@property (nonatomic, assign, readwrite) id<SetupViewControllerDelegate> delegate;

- (void)presentModallyOn:(UIViewController *)parent animated:(BOOL)animated;

@end



@protocol SetupViewControllerDelegate <NSObject>

@required

// string may be empty, to indicate no gallery
- (void)setupViewController:(SetupViewController *)controller didChooseString:(NSString *)string;

- (void)setupViewControllerDidCancel:(SetupViewController *)controller;

@end
    