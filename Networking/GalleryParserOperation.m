/*
    File:       GalleryParserOperation.m
    Contains:   Parses an XML photo gallery.
*/

#import "GalleryParserOperation.h"
#import "Logging.h"
#include <xlocale.h>                                    // for strptime_l



@interface GalleryParserOperation () <NSXMLParserDelegate>
// read/write variants of public properties
@property (copy,   readwrite) NSError *                 error;
// private properties
#if ! defined(NDEBUG)
@property (assign, readwrite) NSTimeInterval            debugDelaySoFar;
#endif
@property (retain, readonly ) NSMutableArray *          mutableResults;
@property (retain, readwrite) NSXMLParser *             parser;
@property (retain, readonly ) NSMutableDictionary *     itemProperties;
@end



@implementation GalleryParserOperation

// See comment in header.
- (id)initWithData:(NSData *)data{
    assert(data != nil);
    self = [super init];
    if (self != nil) {
        self->_data = [data copy];
        self->_mutableResults  = [[NSMutableArray alloc] init];
        assert(self->_mutableResults != nil);
        self->_itemProperties = [[NSMutableDictionary alloc] init];
        assert(self->_itemProperties != nil);
    }
    return self;
}

- (void)dealloc{
    [self->_data release];
    [self->_error release];
    [self->_parser release];
    [self->_mutableResults release];
    [self->_itemProperties release];
    [super dealloc];
}

#if ! defined(NDEBUG)
@synthesize debugDelay      = _debugDelay;
@synthesize debugDelaySoFar = _debugDelaySoFar;
#endif

@synthesize data            = _data;
@synthesize error           = _error;

@synthesize mutableResults  = _mutableResults;
@synthesize parser          = _parser;
@synthesize itemProperties  = _itemProperties;

// Parses the supplied XML date string and returns an NSDate object.  We avoid NSDateFormatter here and do the work using the much lighter  weight strptime_l.
+ (NSDate *)dateFromDateString:(NSString *)string{
/*
    Dates are of the form "2006-07-30T07:47:17Z".
*/
    struct tm   now;
    NSDate *    result;
    BOOL        success;
    
    result = nil;
    success = strptime_l([string UTF8String], "%Y-%m-%dT%H:%M:%SZ", &now, NULL) != NULL;
    if (success) {
        result = [NSDate dateWithTimeIntervalSince1970:timelocal(&now)];
    }
    
    return result;
}

// Returns a copy of the current results.
- (NSArray *)results{
    return [[self->_mutableResults copy] autorelease];
}

- (void)main{
    BOOL        success;

    // Set up the parser.  We keep this in a property so that our delegate callbacks have access to it.
    assert(self.data != nil);
    self.parser = [[[NSXMLParser alloc] initWithData:self.data] autorelease];
    assert(self.parser != nil);
    
    self.parser.delegate = self;
    
    // Do the parse.
    [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse start"];
    
    success = [self.parser parse];
    if ( ! success ) {
        // If our parser delegate callbacks already set an error, we ignore the error coming back from NSXMLParser.  Our delegate callbacks have the most accurate error info.
        if (self.error == nil) {
            self.error = [self.parser parserError];
            assert(self.error != nil);
        }
    }
    
    // In the debug version, if we've been told to delay, do so.  This gives us time to test the cancellation path.
    #if ! defined(NDEBUG)
        {
            while (self.debugDelaySoFar < self.debugDelay) {
                // We always sleep in one second intervals.  I could do the maths to 
                // sleep for the remaining amount of time or one second, whichever 
                // is the least, but hey, this is debugging code.
                
                [NSThread sleepForTimeInterval:1.0];
                self.debugDelaySoFar += 1.0;
                
                if ( [self isCancelled] ) {
                    // If we notice the cancel, we override any error we got from the XML.
                    self.error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
                    break;
                }
            }
        }
    #endif

    if (self.error == nil) {
        [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse success"];
    } else {
        [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse failed %@", self.error];
    }
    
    self.parser = nil;
}

/*
    Here's an example of a "photo" element in our XML:
    
    <photo name="Kids In A Box" date="2006-07-30T07:47:17Z" id="12345">
        <image kind="original" src="originals/IMG_1282.JPG" srcURL="originals/IMG_1282.JPG" srcname="IMG_1282.JPG" size="1241626" sizeText="1.2 MB" type="image"></image>
        <image kind="image" src="images/IMG_1282.JPG" srcURL="images/IMG_1282.JPG" srcname="IMG_1282.JPG" size="1129805" sizeText="1 MB" type="image" width="2048" height="1536"></image>
        <image kind="thumbnail" src="thumbnails/IMG_1282.jpg" srcURL="thumbnails/IMG_1282.jpg" srcname="IMG_1282.jpg" size="29295" sizeText="28.6 KB" type="image" width="300" height="225"></image>
    </photo>
*/

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict{
  // 	NSLog(@"parser:%@ didStartElement:%@ namespaceURI:%@ qualifiedName:%@ attributes:%@",parser, elementName, namespaceURI, qName, attributeDict);

	assert(parser == self.parser);
    #pragma unused(parser)
    #pragma unused(namespaceURI)
    #pragma unused(qName)
    #pragma unused(attributeDict)
    
    // In the debug build, if we've been told to delay, and we haven't already delayed 
    // enough, just sleep for 0.1 seconds.
    
    #if ! defined(NDEBUG)
        if (self.debugDelaySoFar < self.debugDelay) {
            [NSThread sleepForTimeInterval:0.1];
            self.debugDelaySoFar += 0.1;
        }
    #endif
    
    // Check for cancellation at the start of each element.
    
    if ( [self isCancelled] ) {
        self.error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        [self.parser abortParsing];
    } else if ( [elementName isEqual:@"photo"] ) {
        NSString *  tmpStr; //date
        NSString *  photoID;
        NSString *  name;
        NSDate *    date;
        
        // We're at the start of a "photo" element.  Set up the itemProperties dictionary.

        [self.itemProperties removeAllObjects];
        
        photoID = nil;
        name = nil;
        date = nil;
        
        photoID = [attributeDict objectForKey:@"id"];
        name    = [attributeDict objectForKey:@"name"];
        tmpStr  = [attributeDict objectForKey:@"date"];
        if (tmpStr != nil) {
            date = [[self class] dateFromDateString:tmpStr];
            if (date == nil) {
                [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo date error '%@'", tmpStr];
            }
        }

        if ( (photoID == nil) || ([photoID length] == 0) ) {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing 'id'"];
        } else if ( (name == nil) || ([name length] == 0) ) {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing 'name'"];
        } else if (date == nil) {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing 'date'"];
        } else {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo start %@", photoID];
            [self.itemProperties setObject:photoID forKey:kGalleryParserResultPhotoID];
            [self.itemProperties setObject:name    forKey:kGalleryParserResultName];
            [self.itemProperties setObject:date    forKey:kGalleryParserResultDate];
        }
    } else if ( [elementName isEqual:@"image"] ) {
        if ( [self.itemProperties count] == 0 ) {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo image skipped, out of context"];
        } else {
            NSString *  kindStr;
            NSString *  srcURLStr;
            
            // We're at the start of an "image" element.  Check to see whether it's an image 
            // we care about.  If so, add the "srcURL" attribute to our itemProperties dictionary.
            
            kindStr   = [attributeDict objectForKey:@"kind"];
            srcURLStr = [attributeDict objectForKey:@"srcURL"];
            if ( (srcURLStr != nil) && ([srcURLStr length] != 0) ) {
                if ( [kindStr isEqual:@"image"] ) {
                    [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo image '%@'", srcURLStr];
                    [self.itemProperties setObject:srcURLStr forKey:kGalleryParserResultPhotoPath];
                } else if ( [kindStr isEqual:@"thumbnail"] ) {
                    [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo thumbnail '%@'", srcURLStr];
                    [self.itemProperties setObject:srcURLStr forKey:kGalleryParserResultThumbnailPath];
                }
            }
        }
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName{
  	//NSLog(@"parser:%@ didEndElement:%@ namespaceURI:%@ qualifiedName:%@", parser, elementName, namespaceURI,  qName );

	assert(parser == self.parser);
    #pragma unused(parser)
    #pragma unused(namespaceURI)
    #pragma unused(qName)
    
    // At the end of the "photo" element, check to see we got all of the required 
    // properties and, if so, add an item to the result.
    if ( [elementName isEqual:@"photo"] ) {
        if ([self.itemProperties count] == 0) {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, out of context"];
        } 
		else {
            if ([self.itemProperties objectForKey:kGalleryParserResultPhotoPath] == nil) {
                [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing image"];
            } 
			else if ([self.itemProperties objectForKey:kGalleryParserResultThumbnailPath] == nil) {
                [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing thumbnail"];
            } 
			else {
                assert([[self.itemProperties objectForKey:kGalleryParserResultPhotoID      ] isKindOfClass:[NSString class]]);
                assert([[self.itemProperties objectForKey:kGalleryParserResultName         ] isKindOfClass:[NSString class]]);
                assert([[self.itemProperties objectForKey:kGalleryParserResultDate         ] isKindOfClass:[NSDate   class]]);
                assert([[self.itemProperties objectForKey:kGalleryParserResultPhotoPath    ] isKindOfClass:[NSString class]]);
                assert([[self.itemProperties objectForKey:kGalleryParserResultThumbnailPath] isKindOfClass:[NSString class]]);
                [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo success %@", [self.itemProperties objectForKey:kGalleryParserResultPhotoID]];
                [self.mutableResults addObject:[[self.itemProperties copy] autorelease]];
                [self.itemProperties removeAllObjects];
            }
        }
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string{
	NSLog(@"parser:%@ foundCharacters:%@", parser, string);
}


@end

NSString * kGalleryParserResultPhotoID       = @"photoID";
NSString * kGalleryParserResultName          = @"name";
NSString * kGalleryParserResultDate          = @"date";
NSString * kGalleryParserResultPhotoPath     = @"photoPath";
NSString * kGalleryParserResultThumbnailPath = @"thumbnailPath";
