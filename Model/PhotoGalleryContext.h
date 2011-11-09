/*
    File:       PhotoGalleryContext.h
    Contains:   A managed object context subclass that carries along some photo gallery info.
*/

#import <CoreData/CoreData.h>
/*
 PhotoGalleryContext.  This is an NSManagedObjectContext subclass that holds information about the photo gallery.  
 This allows managed objects, specifically the Photo objects, to get at gallery state, such as the gallery URL.

 

// There's a one-to-one relationship between PhotoGallery and PhotoGalleryContext objects. 
// The reason why certain bits of state are stored here, rather than in PhotoGallery, is 
// so that managed objects, specifically the Photo objects, can get access to this state 
// easily (via their managedObjectContext property).
*/
@interface PhotoGalleryContext : NSManagedObjectContext {
    NSString *      _galleryURLString;
    NSString *      _galleryCachePath;
}

- (id)initWithGalleryURLString:(NSString *)galleryURLString galleryCachePath:(NSString *)galleryCachePath;

@property (nonatomic, copy,   readonly ) NSString *     galleryURLString;
@property (nonatomic, copy,   readonly ) NSString *     galleryCachePath;       // path to gallery cache directory
@property (nonatomic, copy,   readonly ) NSString *     photosDirectoryPath;    // path to Photos directory within galleryCachePath

/*
 // Returns a mutable request that's configured to do an HTTP GET operation 
 // for a resources with the given path relative to the galleryURLString. 
 // If path is nil, returns a request for the galleryURLString resource 
 // itself.  This can return fail (and return nil) if path is not nil and 
 // yet not a valid URL path.
 */
- (NSMutableURLRequest *)requestToGetGalleryRelativeString:(NSString *)path;
   

@end
