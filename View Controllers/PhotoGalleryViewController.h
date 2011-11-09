/*
    File:       PhotoGalleryViewController.h

    Contains:   Shows a list of all the photos in a gallery.

 
 PhotoGalleryViewController -- This table view controller subclass displays a list of photos, with their thumbnails, 
 names and dates.  The core of this view controller is remarkably simple; it just uses an NSFetchedResultsController to get, 
 sort and maintain the list of photos and then populates a table view based on that.  Beyond that, there are two additional
 wrinkles:
 
 - The view controller has a photoGallery properties that determines the gallery it will display.  This property is read/write, 
 and is modified by the application delegate as the user changes between galleries.  Handling a change of galleries is a little
 tricky.  The controller uses KVO to do this; it simply observes its own photoGallery property and responds to changes from there.
 
 - The view controller maintains a toolbar at the bottom that display sync status from the underlying photo gallery, and includes 
 a Refresh button that the user can tap to force a sync (or stop the sync if one is already in progress).
 
 Finally, the PhotoGalleryViewController uses a custom table view cell, PhotoCell, to actually display the photo.  This cell is
 passed a Photo object and uses KVO to automatically respond to changes in that object.
*/

#import <UIKit/UIKit.h>

#import <CoreData/CoreData.h>

@class PhotoGallery;

@interface PhotoGalleryViewController : UITableViewController
{
    UIBarButtonItem *               _stopBarButtonItem;
    UIBarButtonItem *               _refreshBarButtonItem;
    UIBarButtonItem *               _fixedBarButtonItem;
    UIBarButtonItem *               _flexBarButtonItem;
    UIBarButtonItem *               _statusBarButtonItem;
    
    PhotoGallery *                  _photoGallery;
    NSFetchedResultsController *    _fetcher;
    NSDateFormatter *               _dateFormatter;
}

/*
 // Creates a view controller to show the photos in the specified gallery. 
 //
 // IMPORTANT: photoGallery may be nil, in which case it simply displays 
 // a placeholder UI.
 */
- (id)initWithPhotoGallery:(PhotoGallery *)photoGallery;
    
// The client can change the gallery being shown by setting this property.
@property (nonatomic, retain, readwrite) PhotoGallery *     photoGallery;

@end