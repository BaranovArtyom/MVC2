/*
    File:       PhotoGalleryContext.m
    Contains:   A managed object context subclass that carries along some photo gallery info.s
*/

#import "PhotoGalleryContext.h"
#import "NetworkManager.h"


@implementation PhotoGalleryContext

- (id)initWithGalleryURLString:(NSString *)galleryURLString galleryCachePath:(NSString *)galleryCachePath{
    assert(galleryURLString != nil);
    assert(galleryCachePath != nil);
    
    self = [super init];
    if (self != nil) {
        self->_galleryURLString = [galleryURLString copy];
        self->_galleryCachePath = [galleryCachePath copy];
    }
    return self;
}

- (void)dealloc{
    [self->_galleryCachePath release];
    [self->_galleryURLString release];
    [super dealloc];
}

@synthesize galleryURLString = _galleryURLString;
@synthesize galleryCachePath = _galleryCachePath;

- (NSString *)photosDirectoryPath{
    // This comes from the PhotoGallery class.  I didn't really want to include it's header 
    // here (because we are 'lower' in the architecture than PhotoGallery), and I don't want 
    // the declaration in "PhotoGalleryContext.h" either (because our public clients have 
    // no need of this).  The best solution would be to have "PhotoGalleryPrivate.h", and 
    // put all the gallery cache structure strings into that file.  But having a whole separate 
    // file just to solve that problem seems like overkill.  So, for the moment, we just 
    // declare it extern here.
    extern NSString * kPhotosDirectoryName;
    return [self.galleryCachePath stringByAppendingPathComponent:kPhotosDirectoryName];
}

// See comment in header.
- (NSMutableURLRequest *)requestToGetGalleryRelativeString:(NSString *)path{
    NSMutableURLRequest *   result;
    NSURL *                 url;

    assert([NSThread isMainThread]);
    assert(self.galleryURLString != nil);

    result = nil;
    
    // Construct the URL.
    
    url = [NSURL URLWithString:self.galleryURLString];
    assert(url != nil);
    if (path != nil) {
        url = [NSURL URLWithString:path relativeToURL:url];
        // url may be nil because, while galleryURLString is guaranteed to be a valid 
        // URL, path may not be.
    }
    
    // Call down to the network manager so that it can set up its stuff 
    // (notably the user agent string).
    
    if (url != nil) {
        result = [[NetworkManager sharedManager] requestToGetURL:url];
        assert(result != nil);
    }
    
    return result;
}

@end
