/*
    File:       Thumbnail.h
    Contains:   Model object for a thumbnail.
*/

#import <CoreData/CoreData.h>
/*
  Thumbnail holds the data for a thumbnail.  Again, this is a managed object.  It is separated from the Photo class because 
 its properties are large (the thumbnail's PNG representation) and, in general, it's a good idea to separate large objects from 
 small objects within a Core Data database.

// In contrast to the Photo class, the Thumbnail class is entirely passive. 
// It's just a dumb container for the thumbnail data.
//
// Keep in mind that, by default, managed object properties are retained, not 
// copied, so clients of Thumbnail must be careful if they assign potentially 
// mutable data to the imageData property.
 */
@class Photo;

@interface Thumbnail :  NSManagedObject  

@property (nonatomic, retain, readwrite) NSData *   imageData;      // holds a PNG representation of the thumbnail
@property (nonatomic, retain, readwrite) Photo *    photo;          // a pointer back to the owning photo

@end
