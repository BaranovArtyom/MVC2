/*
    File:       RecursiveDeleteOperation.h
    Contains:   Recursively deletes an array of file paths.
*/

#import <Foundation/Foundation.h>

@interface RecursiveDeleteOperation : NSOperation
{
    NSArray *   _paths;
    NSError *   _error;
}

// Configures the operation with the array of paths to delete.
- (id)initWithPaths:(NSArray *)paths;

// properties specified at init time
@property (copy,   readonly ) NSArray *     paths;

// properties that are valid after the operation is finished
@property (copy,   readonly ) NSError *     error;

@end
