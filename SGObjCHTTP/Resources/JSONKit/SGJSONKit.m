//
//  JSONKit.m
//  http://github.com/johnezang/JSONKit
//  Dual licensed under either the terms of the BSD License, or alternatively
//  under the terms of the Apache License, Version 2.0, as specified below.
//

/*
 Copyright (c) 2011, John Engelhart
 
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 
 * Neither the name of the Zang Industries nor the names of its
 contributors may be used to endorse or promote products derived from
 this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

/*
 Copyright 2011 John Engelhart
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BasiS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
*/


/*
  Acknowledgments:

  The bulk of the UTF8 / UTF32 conversion and verification comes
  from ConvertUTF.[hc].  It has been modified from the original sources.

  The original sources were obtained from http://www.unicode.org/.
  However, the web site no longer seems to host the files.  Instead,
  the Unicode FAQ http://www.unicode.org/faq//utf_bom.html#gen4
  points to International Components for Unicode (ICU)
  http://site.icu-project.org/ as an example of how to write a UTF
  converter.

  The decision to use the ConvertUTF.[ch] code was made to leverage
  "proven" code.  Hopefully the local modifications are bug free.

  The code in isValidCodePoint() is derived from the ICU code in
  utf.h for the macros U_IS_UNICODE_NONCHAR and U_IS_UNICODE_CHAR.

  From the original ConvertUTF.[ch]:

 * Copyright 2001-2004 Unicode, Inc.
 * 
 * Disclaimer
 * 
 * This source code is provided as is by Unicode, Inc. No claims are
 * made as to fitness for any particular purpose. No warranties of any
 * kind are expressed or implied. The recipient agrees to determine
 * applicability of information provided. If this file has been
 * purchased on magnetic or optical media from Unicode, Inc., the
 * sole remedy for any claim will be exchange of defective media
 * within 90 days of receipt.
 * 
 * Limitations on Rights to Redistribute This Code
 * 
 * Unicode, Inc. hereby grants the right to freely use the information
 * supplied in this file in the creation of products supporting the
 * Unicode Standard, and to make copies of this file in any form
 * for internal or external distribution as long as this notice
 * remains attached.

*/

// !!! NOTE !!!
//
// The content has been modified in order to address
// namespacing issues.
//
// !!! NOTE !!!

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <sys/errno.h>
#include <math.h>
#include <limits.h>
#include <objc/runtime.h>

#import "SGJSONKit.h"

//#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFString.h>
#include <CoreFoundation/CFArray.h>
#include <CoreFoundation/CFDictionary.h>
#include <CoreFoundation/CFNumber.h>

//#import <Foundation/Foundation.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSException.h>
#import <Foundation/NSNull.h>
#import <Foundation/NSObjCRuntime.h>

#ifndef __has_feature
#define __has_feature(x) 0
#endif

#ifdef SGJK_ENABLE_CF_TRANSFER_OWNERSHIP_CALLBACKS
#warning As of JSONKit v1.4, SGJK_ENABLE_CF_TRANSFER_OWNERSHIP_CALLBACKS is no longer required.  It is no longer a valid option.
#endif

#ifdef __OBJC_GC__
#error JSONKit does not support Objective-C Garbage Collection
#endif

#if __has_feature(objc_arc)
#error JSONKit does not support Objective-C Automatic Reference Counting (ARC)
#endif

// The following checks are really nothing more than sanity checks.
// JSONKit technically has a few problems from a "strictly C99 conforming" standpoint, though they are of the pedantic nitpicking variety.
// In practice, though, for the compilers and architectures we can reasonably expect this code to be compiled for, these pedantic nitpicks aren't really a problem.
// Since we're limited as to what we can do with pre-processor #if checks, these checks are not nearly as through as they should be.

#if (UINT_MAX != 0xffffffffU) || (INT_MIN != (-0x7fffffff-1)) || (ULLONG_MAX != 0xffffffffffffffffULL) || (LLONG_MIN != (-0x7fffffffffffffffLL-1LL))
#error JSONKit requires the C 'int' and 'long long' types to be 32 and 64 bits respectively.
#endif

#if !defined(__LP64__) && ((UINT_MAX != ULONG_MAX) || (INT_MAX != LONG_MAX) || (INT_MIN != LONG_MIN) || (WORD_BIT != LONG_BIT))
#error JSONKit requires the C 'int' and 'long' types to be the same on 32-bit architectures.
#endif

// Cocoa / Foundation uses NS*Integer as the type for a lot of arguments.  We make sure that NS*Integer is something we are expecting and is reasonably compatible with size_t / ssize_t

#if (NSUIntegerMax != ULONG_MAX) || (NSIntegerMax != LONG_MAX) || (NSIntegerMin != LONG_MIN)
#error JSONKit requires NSInteger and NSUInteger to be the same size as the C 'long' type.
#endif

#if (NSUIntegerMax != SIZE_MAX) || (NSIntegerMax != SSIZE_MAX)
#error JSONKit requires NSInteger and NSUInteger to be the same size as the C 'size_t' type.
#endif


// For DJB hash.
#define SGJK_HASH_INIT           (1402737925UL)

// Use __builtin_clz() instead of trailingBytesForUTF8[] table lookup.
#define SGJK_FAST_TRAILING_BYTES

// SGJK_CACHE_SLOTS must be a power of 2.  Default size is 1024 slots.
#define SGJK_CACHE_SLOTS_BITS    (10)
#define SGJK_CACHE_SLOTS         (1UL << SGJK_CACHE_SLOTS_BITS)
// SGJK_CACHE_PROBES is the number of probe attempts.
#define SGJK_CACHE_PROBES        (4UL)
// SGJK_INIT_CACHE_AGE must be (1 << AGE) - 1
#define SGJK_INIT_CACHE_AGE      (0)

// SGJK_TOKENBUFFER_SIZE is the default stack size for the temporary buffer used to hold "non-simple" strings (i.e., contains \ escapes)
#define SGJK_TOKENBUFFER_SIZE    (1024UL * 2UL)

// SGJK_STACK_OBJS is the default number of spaces reserved on the stack for temporarily storing pointers to Obj-C objects before they can be transferred to a NSArray / NSDictionary.
#define SGJK_STACK_OBJS          (1024UL * 1UL)

#define SGJK_JSONBUFFER_SIZE     (1024UL * 4UL)
#define SGJK_UTF8BUFFER_SIZE     (1024UL * 16UL)

#define SGJK_ENCODE_CACHE_SLOTS  (1024UL)


#if       defined (__GNUC__) && (__GNUC__ >= 4)
#define SGJK_ATTRIBUTES(attr, ...)        __attribute__((attr, ##__VA_ARGS__))
#define SGJK_EXPECTED(cond, expect)       __builtin_expect((long)(cond), (expect))
#define SGJK_EXPECT_T(cond)               SGJK_EXPECTED(cond, 1U)
#define SGJK_EXPECT_F(cond)               SGJK_EXPECTED(cond, 0U)
#define SGJK_PREFETCH(ptr)                __builtin_prefetch(ptr)
#else  // defined (__GNUC__) && (__GNUC__ >= 4) 
#define SGJK_ATTRIBUTES(attr, ...)
#define SGJK_EXPECTED(cond, expect)       (cond)
#define SGJK_EXPECT_T(cond)               (cond)
#define SGJK_EXPECT_F(cond)               (cond)
#define SGJK_PREFETCH(ptr)
#endif // defined (__GNUC__) && (__GNUC__ >= 4) 

#define SGJK_STATIC_INLINE                         static __inline__ SGJK_ATTRIBUTES(always_inline)
#define SGJK_ALIGNED(arg)                                            SGJK_ATTRIBUTES(aligned(arg))
#define SGJK_UNUSED_ARG                                              SGJK_ATTRIBUTES(unused)
#define SGJK_WARN_UNUSED                                             SGJK_ATTRIBUTES(warn_unused_result)
#define SGJK_WARN_UNUSED_CONST                                       SGJK_ATTRIBUTES(warn_unused_result, const)
#define SGJK_WARN_UNUSED_PURE                                        SGJK_ATTRIBUTES(warn_unused_result, pure)
#define SGJK_WARN_UNUSED_SENTINEL                                    SGJK_ATTRIBUTES(warn_unused_result, sentinel)
#define SGJK_NONNULL_ARGS(arg, ...)                                  SGJK_ATTRIBUTES(nonnull(arg, ##__VA_ARGS__))
#define SGJK_WARN_UNUSED_NONNULL_ARGS(arg, ...)                      SGJK_ATTRIBUTES(warn_unused_result, nonnull(arg, ##__VA_ARGS__))
#define SGJK_WARN_UNUSED_CONST_NONNULL_ARGS(arg, ...)                SGJK_ATTRIBUTES(warn_unused_result, const, nonnull(arg, ##__VA_ARGS__))
#define SGJK_WARN_UNUSED_PURE_NONNULL_ARGS(arg, ...)                 SGJK_ATTRIBUTES(warn_unused_result, pure, nonnull(arg, ##__VA_ARGS__))

#if       defined (__GNUC__) && (__GNUC__ >= 4) && (__GNUC_MINOR__ >= 3)
#define SGJK_ALLOC_SIZE_NON_NULL_ARGS_WARN_UNUSED(as, nn, ...) SGJK_ATTRIBUTES(warn_unused_result, nonnull(nn, ##__VA_ARGS__), alloc_size(as))
#else  // defined (__GNUC__) && (__GNUC__ >= 4) && (__GNUC_MINOR__ >= 3)
#define SGJK_ALLOC_SIZE_NON_NULL_ARGS_WARN_UNUSED(as, nn, ...) SGJK_ATTRIBUTES(warn_unused_result, nonnull(nn, ##__VA_ARGS__))
#endif // defined (__GNUC__) && (__GNUC__ >= 4) && (__GNUC_MINOR__ >= 3)


@class SGJKArray, SGJKDictionaryEnumerator, SGJKDictionary;

enum {
  JSONNumberStateStart                 = 0,
  JSONNumberStateFinished              = 1,
  JSONNumberStateError                 = 2,
  JSONNumberStateWholeNumberStart      = 3,
  JSONNumberStateWholeNumberMinus      = 4,
  JSONNumberStateWholeNumberZero       = 5,
  JSONNumberStateWholeNumber           = 6,
  JSONNumberStatePeriod                = 7,
  JSONNumberStateFractionalNumberStart = 8,
  JSONNumberStateFractionalNumber      = 9,
  JSONNumberStateExponentStart         = 10,
  JSONNumberStateExponentPlusMinus     = 11,
  JSONNumberStateExponent              = 12,
};

enum {
  JSONStringStateStart                           = 0,
  JSONStringStateParsing                         = 1,
  JSONStringStateFinished                        = 2,
  JSONStringStateError                           = 3,
  JSONStringStateEscape                          = 4,
  JSONStringStateEscapedUnicode1                 = 5,
  JSONStringStateEscapedUnicode2                 = 6,
  JSONStringStateEscapedUnicode3                 = 7,
  JSONStringStateEscapedUnicode4                 = 8,
  JSONStringStateEscapedUnicodeSurrogate1        = 9,
  JSONStringStateEscapedUnicodeSurrogate2        = 10,
  JSONStringStateEscapedUnicodeSurrogate3        = 11,
  JSONStringStateEscapedUnicodeSurrogate4        = 12,
  JSONStringStateEscapedNeedEscapeForSurrogate   = 13,
  JSONStringStateEscapedNeedEscapedUForSurrogate = 14,
};

enum {
  SGJKParseAcceptValue      = (1 << 0),
  SGJKParseAcceptComma      = (1 << 1),
  SGJKParseAcceptEnd        = (1 << 2),
  SGJKParseAcceptValueOrEnd = (SGJKParseAcceptValue | SGJKParseAcceptEnd),
  SGJKParseAcceptCommaOrEnd = (SGJKParseAcceptComma | SGJKParseAcceptEnd),
};

enum {
  SGJKClassUnknown    = 0,
  SGJKClassString     = 1,
  SGJKClassNumber     = 2,
  SGJKClassArray      = 3,
  SGJKClassDictionary = 4,
  SGJKClassNull       = 5,
};

enum {
  SGJKManagedBufferOnStack        = 1,
  SGJKManagedBufferOnHeap         = 2,
  SGJKManagedBufferLocationMask   = (0x3),
  SGJKManagedBufferLocationShift  = (0),
  
  SGJKManagedBufferMustFree       = (1 << 2),
};
typedef SGJKFlags SGJKManagedBufferFlags;

enum {
  SGJKObjectStackOnStack        = 1,
  SGJKObjectStackOnHeap         = 2,
  SGJKObjectStackLocationMask   = (0x3),
  SGJKObjectStackLocationShift  = (0),
  
  SGJKObjectStackMustFree       = (1 << 2),
};
typedef SGJKFlags SGJKObjectStackFlags;

enum {
  SGJKTokenTypeInvalid     = 0,
  SGJKTokenTypeNumber      = 1,
  SGJKTokenTypeString      = 2,
  SGJKTokenTypeObjectBegin = 3,
  SGJKTokenTypeObjectEnd   = 4,
  SGJKTokenTypeArrayBegin  = 5,
  SGJKTokenTypeArrayEnd    = 6,
  SGJKTokenTypeSeparator   = 7,
  SGJKTokenTypeComma       = 8,
  SGJKTokenTypeTrue        = 9,
  SGJKTokenTypeFalse       = 10,
  SGJKTokenTypeNull        = 11,
  SGJKTokenTypeWhiteSpace  = 12,
};
typedef NSUInteger SGJKTokenType;

// These are prime numbers to assist with hash slot probing.
enum {
  SGJKValueTypeNone             = 0,
  SGJKValueTypeString           = 5,
  SGJKValueTypeLongLong         = 7,
  SGJKValueTypeUnsignedLongLong = 11,
  SGJKValueTypeDouble           = 13,
};
typedef NSUInteger SGJKValueType;

enum {
  SGJKEncodeOptionAsData              = 1,
  SGJKEncodeOptionAsString            = 2,
  SGJKEncodeOptionAsTypeMask          = 0x7,
  SGJKEncodeOptionCollectionObj       = (1 << 3),
  SGJKEncodeOptionStringObj           = (1 << 4),
  SGJKEncodeOptionStringObjTrimQuotes = (1 << 5),
  
};
typedef NSUInteger SGJKEncodeOptionType;

typedef NSUInteger SGJKHash;

typedef struct SGJKTokenCacheItem  SGJKTokenCacheItem;
typedef struct SGJKTokenCache      SGJKTokenCache;
typedef struct SGJKTokenValue      SGJKTokenValue;
typedef struct SGJKParseToken      SGJKParseToken;
typedef struct SGJKPtrRange        SGJKPtrRange;
typedef struct SGJKObjectStack     SGJKObjectStack;
typedef struct SGJKBuffer          SGJKBuffer;
typedef struct SGJKConstBuffer     SGJKConstBuffer;
typedef struct SGJKConstPtrRange   SGJKConstPtrRange;
typedef struct SGJKRange           SGJKRange;
typedef struct SGJKManagedBuffer   SGJKManagedBuffer;
typedef struct SGJKFastClassLookup SGJKFastClassLookup;
typedef struct SGJKEncodeCache     SGJKEncodeCache;
typedef struct SGJKEncodeState     SGJKEncodeState;
typedef struct SGJKObjCImpCache    SGJKObjCImpCache;
typedef struct SGJKHashTableEntry  SGJKHashTableEntry;

typedef id (*NSNumberAllocImp)(id receiver, SEL selector);
typedef id (*NSNumberInitWithUnsignedLongLongImp)(id receiver, SEL selector, unsigned long long value);
typedef id (*SGJKClassFormatterIMP)(id receiver, SEL selector, id object);
#ifdef __BLOCKS__
typedef id (^SGJKClassFormatterBlock)(id formatObject);
#endif


struct SGJKPtrRange {
  unsigned char *ptr;
  size_t         length;
};

struct SGJKConstPtrRange {
  const unsigned char *ptr;
  size_t               length;
};

struct SGJKRange {
  size_t location, length;
};

struct SGJKManagedBuffer {
  SGJKPtrRange           bytes;
  SGJKManagedBufferFlags flags;
  size_t               roundSizeUpToMultipleOf;
};

struct SGJKObjectStack {
  void               **objects, **keys;
  CFHashCode          *cfHashes;
  size_t               count, index, roundSizeUpToMultipleOf;
  SGJKObjectStackFlags   flags;
};

struct SGJKBuffer {
  SGJKPtrRange bytes;
};

struct SGJKConstBuffer {
  SGJKConstPtrRange bytes;
};

struct SGJKTokenValue {
  SGJKConstPtrRange   ptrRange;
  SGJKValueType       type;
  SGJKHash            hash;
  union {
    long long          longLongValue;
    unsigned long long unsignedLongLongValue;
    double             doubleValue;
  } number;
  SGJKTokenCacheItem *cacheItem;
};

struct SGJKParseToken {
  SGJKConstPtrRange tokenPtrRange;
  SGJKTokenType     type;
  SGJKTokenValue    value;
  SGJKManagedBuffer tokenBuffer;
};

struct SGJKTokenCacheItem {
  void          *object;
  SGJKHash         hash;
  CFHashCode     cfHash;
  size_t         size;
  unsigned char *bytes;
  SGJKValueType    type;
};

struct SGJKTokenCache {
  SGJKTokenCacheItem *items;
  size_t            count;
  unsigned int      prng_lfsr;
  unsigned char     age[SGJK_CACHE_SLOTS];
};

struct SGJKObjCImpCache {
  Class                               NSNumberClass;
  NSNumberAllocImp                    NSNumberAlloc;
  NSNumberInitWithUnsignedLongLongImp NSNumberInitWithUnsignedLongLong;
};

struct SGJKParseState {
  SGJKParseOptionFlags  parseOptionFlags;
  SGJKConstBuffer       stringBuffer;
  size_t              atIndex, lineNumber, lineStartIndex;
  size_t              prev_atIndex, prev_lineNumber, prev_lineStartIndex;
  SGJKParseToken        token;
  SGJKObjectStack       objectStack;
  SGJKTokenCache        cache;
  SGJKObjCImpCache      objCImpCache;
  NSError            *error;
  int                 errorIsPrev;
  BOOL                mutableCollections;
};

struct SGJKFastClassLookup {
  void *stringClass;
  void *numberClass;
  void *arrayClass;
  void *dictionaryClass;
  void *nullClass;
};

struct SGJKEncodeCache {
  id object;
  size_t offset;
  size_t length;
};

struct SGJKEncodeState {
  SGJKManagedBuffer         utf8ConversionBuffer;
  SGJKManagedBuffer         stringBuffer;
  size_t                  atIndex;
  SGJKFastClassLookup       fastClassLookup;
  SGJKEncodeCache           cache[SGJK_ENCODE_CACHE_SLOTS];
  SGJKSerializeOptionFlags  serializeOptionFlags;
  SGJKEncodeOptionType      encodeOption;
  size_t                  depth;
  NSError                *error;
  id                      classFormatterDelegate;
  SEL                     classFormatterSelector;
  SGJKClassFormatterIMP     classFormatterIMP;
#ifdef __BLOCKS__
  SGJKClassFormatterBlock   classFormatterBlock;
#endif
};

// This is a JSONKit private class.
@interface SGJKSerializer : NSObject {
  SGJKEncodeState *encodeState;
}

#ifdef __BLOCKS__
#define SGJKSERIALIZER_BLOCKS_PROTO id(^)(id object)
#else
#define SGJKSERIALIZER_BLOCKS_PROTO id
#endif

+ (id)serializeObject:(id)object options:(SGJKSerializeOptionFlags)optionFlags encodeOption:(SGJKEncodeOptionType)encodeOption block:(SGJKSERIALIZER_BLOCKS_PROTO)block delegate:(id)delegate selector:(SEL)selector error:(NSError **)error;
- (id)serializeObject:(id)object options:(SGJKSerializeOptionFlags)optionFlags encodeOption:(SGJKEncodeOptionType)encodeOption block:(SGJKSERIALIZER_BLOCKS_PROTO)block delegate:(id)delegate selector:(SEL)selector error:(NSError **)error;
- (void)releaseState;

@end

struct SGJKHashTableEntry {
  NSUInteger keyHash;
  id key, object;
};


typedef uint32_t UTF32; /* at least 32 bits */
typedef uint16_t UTF16; /* at least 16 bits */
typedef uint8_t  UTF8;  /* typically 8 bits */

typedef enum {
  conversionOK,           /* conversion successful */
  sourceExhausted,        /* partial character in source, but hit end */
  targetExhausted,        /* insuff. room in target for conversion */
  sourceIllegal           /* source sequence is illegal/malformed */
} ConversionResult;

#define UNI_REPLACEMENT_CHAR (UTF32)0x0000FFFD
#define UNI_MAX_BMP          (UTF32)0x0000FFFF
#define UNI_MAX_UTF16        (UTF32)0x0010FFFF
#define UNI_MAX_UTF32        (UTF32)0x7FFFFFFF
#define UNI_MAX_LEGAL_UTF32  (UTF32)0x0010FFFF
#define UNI_SUR_HIGH_START   (UTF32)0xD800
#define UNI_SUR_HIGH_END     (UTF32)0xDBFF
#define UNI_SUR_LOW_START    (UTF32)0xDC00
#define UNI_SUR_LOW_END      (UTF32)0xDFFF


#if !defined(SGJK_FAST_TRAILING_BYTES)
static const char trailingBytesForUTF8[256] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, 3,3,3,3,3,3,3,3,4,4,4,4,5,5,5,5
};
#endif

static const UTF32 offsetsFromUTF8[6] = { 0x00000000UL, 0x00003080UL, 0x000E2080UL, 0x03C82080UL, 0xFA082080UL, 0x82082080UL };
static const UTF8  firstByteMark[7]   = { 0x00, 0x00, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC };

#define SGJK_AT_STRING_PTR(x)  (&((x)->stringBuffer.bytes.ptr[(x)->atIndex]))
#define SGJK_END_STRING_PTR(x) (&((x)->stringBuffer.bytes.ptr[(x)->stringBuffer.bytes.length]))


static SGJKArray          *_SGJKArrayCreate(id *objects, NSUInteger count, BOOL mutableCollection);
static void              _SGJKArrayInsertObjectAtIndex(SGJKArray *array, id newObject, NSUInteger objectIndex);
static void              _SGJKArrayReplaceObjectAtIndexWithObject(SGJKArray *array, NSUInteger objectIndex, id newObject);
static void              _SGJKArrayRemoveObjectAtIndex(SGJKArray *array, NSUInteger objectIndex);


static NSUInteger        _SGJKDictionaryCapacityForCount(NSUInteger count);
static SGJKDictionary     *_SGJKDictionaryCreate(id *keys, NSUInteger *keyHashes, id *objects, NSUInteger count, BOOL mutableCollection);
static SGJKHashTableEntry *_SGJKDictionaryHashEntry(SGJKDictionary *dictionary);
static NSUInteger        _SGJKDictionaryCapacity(SGJKDictionary *dictionary);
static void              _SGJKDictionaryResizeIfNeccessary(SGJKDictionary *dictionary);
static void              _SGJKDictionaryRemoveObjectWithEntry(SGJKDictionary *dictionary, SGJKHashTableEntry *entry);
static void              _SGJKDictionaryAddObject(SGJKDictionary *dictionary, NSUInteger keyHash, id key, id object);
static SGJKHashTableEntry *_SGJKDictionaryHashTableEntryForKey(SGJKDictionary *dictionary, id aKey);


static void _JSONDecoderCleanup(SGJSONDecoder *decoder);

static id _NSStringObjectFromJSONString(NSString *jsonString, SGJKParseOptionFlags parseOptionFlags, NSError **error, BOOL mutableCollection);


static void SGJK_managedBuffer_release(SGJKManagedBuffer *managedBuffer);
static void SGJK_managedBuffer_setToStackBuffer(SGJKManagedBuffer *managedBuffer, unsigned char *ptr, size_t length);
static unsigned char *SGJK_managedBuffer_resize(SGJKManagedBuffer *managedBuffer, size_t newSize);
static void SGJK_objectStack_release(SGJKObjectStack *objectStack);
static void SGJK_objectStack_setToStackBuffer(SGJKObjectStack *objectStack, void **objects, void **keys, CFHashCode *cfHashes, size_t count);
static int  SGJK_objectStack_resize(SGJKObjectStack *objectStack, size_t newCount);

static void   SGJK_error(SGJKParseState *parseState, NSString *format, ...);
static int    SGJK_parse_string(SGJKParseState *parseState);
static int    SGJK_parse_number(SGJKParseState *parseState);
static size_t SGJK_parse_is_newline(SGJKParseState *parseState, const unsigned char *atCharacterPtr);
SGJK_STATIC_INLINE int SGJK_parse_skip_newline(SGJKParseState *parseState);
SGJK_STATIC_INLINE void SGJK_parse_skip_whitespace(SGJKParseState *parseState);
static int    SGJK_parse_next_token(SGJKParseState *parseState);
static void   SGJK_error_parse_accept_or3(SGJKParseState *parseState, int state, NSString *or1String, NSString *or2String, NSString *or3String);
static void  *SGJK_create_dictionary(SGJKParseState *parseState, size_t startingObjectIndex);
static void  *SGJK_parse_dictionary(SGJKParseState *parseState);
static void  *SGJK_parse_array(SGJKParseState *parseState);
static void  *SGJK_object_for_token(SGJKParseState *parseState);
static void  *SGJK_cachedObjects(SGJKParseState *parseState);
SGJK_STATIC_INLINE void SGJK_cache_age(SGJKParseState *parseState);
SGJK_STATIC_INLINE void SGJK_set_parsed_token(SGJKParseState *parseState, const unsigned char *ptr, size_t length, SGJKTokenType type, size_t advanceBy);


static void SGJK_encode_error(SGJKEncodeState *encodeState, NSString *format, ...);
static int SGJK_encode_printf(SGJKEncodeState *encodeState, SGJKEncodeCache *cacheSlot, size_t startingAtIndex, id object, const char *format, ...);
static int SGJK_encode_write(SGJKEncodeState *encodeState, SGJKEncodeCache *cacheSlot, size_t startingAtIndex, id object, const char *format);
static int SGJK_encode_writePrettyPrintWhiteSpace(SGJKEncodeState *encodeState);
static int SGJK_encode_write1slow(SGJKEncodeState *encodeState, ssize_t depthChange, const char *format);
static int SGJK_encode_write1fast(SGJKEncodeState *encodeState, ssize_t depthChange SGJK_UNUSED_ARG, const char *format);
static int SGJK_encode_writen(SGJKEncodeState *encodeState, SGJKEncodeCache *cacheSlot, size_t startingAtIndex, id object, const char *format, size_t length);
SGJK_STATIC_INLINE SGJKHash SGJK_encode_object_hash(void *objectPtr);
SGJK_STATIC_INLINE void SGJK_encode_updateCache(SGJKEncodeState *encodeState, SGJKEncodeCache *cacheSlot, size_t startingAtIndex, id object);
static int SGJK_encode_add_atom_to_buffer(SGJKEncodeState *encodeState, void *objectPtr);

#define SGJK_encode_write1(es, dc, f)  (SGJK_EXPECT_F(_SGJK_encode_prettyPrint) ? SGJK_encode_write1slow(es, dc, f) : SGJK_encode_write1fast(es, dc, f))


SGJK_STATIC_INLINE size_t SGJK_min(size_t a, size_t b);
SGJK_STATIC_INLINE size_t SGJK_max(size_t a, size_t b);
SGJK_STATIC_INLINE SGJKHash calculateHash(SGJKHash currentHash, unsigned char c);

// JSONKit v1.4 used both a SGJKArray : NSArray and SGJKMutableArray : NSMutableArray, and the same for the dictionary collection type.
// However, Louis Gerbarg (via cocoa-dev) pointed out that Cocoa / Core Foundation actually implements only a single class that inherits from the 
// mutable version, and keeps an ivar bit for whether or not that instance is mutable.  This means that the immutable versions of the collection
// classes receive the mutating methods, but this is handled by having those methods throw an exception when the ivar bit is set to immutable.
// We adopt the same strategy here.  It's both cleaner and gets rid of the method swizzling hackery used in JSONKit v1.4.


// This is a workaround for issue #23 https://github.com/johnezang/JSONKit/pull/23
// Basically, there seem to be a problem with using +load in static libraries on iOS.  However, __attribute__ ((constructor)) does work correctly.
// Since we do not require anything "special" that +load provides, and we can accomplish the same thing using __attribute__ ((constructor)), the +load logic was moved here.

static Class                               _SGJKArrayClass                           = NULL;
static size_t                              _SGJKArrayInstanceSize                    = 0UL;
static Class                               _SGJKDictionaryClass                      = NULL;
static size_t                              _SGJKDictionaryInstanceSize               = 0UL;

// For SGJSONDecoder...
static Class                               _SGJK_NSNumberClass                       = NULL;
static NSNumberAllocImp                    _SGJK_NSNumberAllocImp                    = NULL;
static NSNumberInitWithUnsignedLongLongImp _SGJK_NSNumberInitWithUnsignedLongLongImp = NULL;

extern void SGJK_collectionClassLoadTimeInitialization(void) __attribute__ ((constructor));

void SGJK_collectionClassLoadTimeInitialization(void) {
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init]; // Though technically not required, the run time environment at load time initialization may be less than ideal.
  
  _SGJKArrayClass             = objc_getClass("SGJKArray");
  _SGJKArrayInstanceSize      = SGJK_max(16UL, class_getInstanceSize(_SGJKArrayClass));
  
  _SGJKDictionaryClass        = objc_getClass("SGJKDictionary");
  _SGJKDictionaryInstanceSize = SGJK_max(16UL, class_getInstanceSize(_SGJKDictionaryClass));
  
  // For SGJSONDecoder...
  _SGJK_NSNumberClass = [NSNumber class];
  _SGJK_NSNumberAllocImp = (NSNumberAllocImp)[NSNumber methodForSelector:@selector(alloc)];
  
  // Hacktacular.  Need to do it this way due to the nature of class clusters.
  id temp_NSNumber = [NSNumber alloc];
  _SGJK_NSNumberInitWithUnsignedLongLongImp = (NSNumberInitWithUnsignedLongLongImp)[temp_NSNumber methodForSelector:@selector(initWithUnsignedLongLong:)];
  [[temp_NSNumber init] release];
  temp_NSNumber = NULL;
  
  [pool release]; pool = NULL;
}


#pragma mark -
@interface SGJKArray : NSMutableArray <NSCopying, NSMutableCopying, NSFastEnumeration> {
  id         *objects;
  NSUInteger  count, capacity, mutations;
}
@end

@implementation SGJKArray

+ (id)allocWithZone:(NSZone *)zone
{
#pragma unused(zone)
  [NSException raise:NSInvalidArgumentException format:@"*** - [%@ %@]: The %@ class is private to JSONKit and should not be used in this fashion.", NSStringFromClass([self class]), NSStringFromSelector(_cmd), NSStringFromClass([self class])];
  return(NULL);
}

static SGJKArray *_SGJKArrayCreate(id *objects, NSUInteger count, BOOL mutableCollection) {
  NSCParameterAssert((objects != NULL) && (_SGJKArrayClass != NULL) && (_SGJKArrayInstanceSize > 0UL));
  SGJKArray *array = NULL;
  if(SGJK_EXPECT_T((array = (SGJKArray *)calloc(1UL, _SGJKArrayInstanceSize)) != NULL)) { // Directly allocate the SGJKArray instance via calloc.
    array->isa      = _SGJKArrayClass;
    if((array = [array init]) == NULL) { return(NULL); }
    array->capacity = count;
    array->count    = count;
    if(SGJK_EXPECT_F((array->objects = (id *)malloc(sizeof(id) * array->capacity)) == NULL)) { [array autorelease]; return(NULL); }
    memcpy(array->objects, objects, array->capacity * sizeof(id));
    array->mutations = (mutableCollection == NO) ? 0UL : 1UL;
  }
  return(array);
}

// Note: The caller is responsible for -retaining the object that is to be added.
static void _SGJKArrayInsertObjectAtIndex(SGJKArray *array, id newObject, NSUInteger objectIndex) {
  NSCParameterAssert((array != NULL) && (array->objects != NULL) && (array->count <= array->capacity) && (objectIndex <= array->count) && (newObject != NULL));
  if(!((array != NULL) && (array->objects != NULL) && (objectIndex <= array->count) && (newObject != NULL))) { [newObject autorelease]; return; }
  array->count++;
  if(array->count >= array->capacity) {
    array->capacity += 16UL;
    id *newObjects = NULL;
    if((newObjects = (id *)realloc(array->objects, sizeof(id) * array->capacity)) == NULL) { [NSException raise:NSMallocException format:@"Unable to resize objects array."]; }
    array->objects = newObjects;
    memset(&array->objects[array->count], 0, sizeof(id) * (array->capacity - array->count));
  }
  if((objectIndex + 1UL) < array->count) { memmove(&array->objects[objectIndex + 1UL], &array->objects[objectIndex], sizeof(id) * ((array->count - 1UL) - objectIndex)); array->objects[objectIndex] = NULL; }
  array->objects[objectIndex] = newObject;
}

// Note: The caller is responsible for -retaining the object that is to be added.
static void _SGJKArrayReplaceObjectAtIndexWithObject(SGJKArray *array, NSUInteger objectIndex, id newObject) {
  NSCParameterAssert((array != NULL) && (array->objects != NULL) && (array->count <= array->capacity) && (objectIndex < array->count) && (array->objects[objectIndex] != NULL) && (newObject != NULL));
  if(!((array != NULL) && (array->objects != NULL) && (objectIndex < array->count) && (array->objects[objectIndex] != NULL) && (newObject != NULL))) { [newObject autorelease]; return; }
  CFRelease(array->objects[objectIndex]);
  array->objects[objectIndex] = NULL;
  array->objects[objectIndex] = newObject;
}

static void _SGJKArrayRemoveObjectAtIndex(SGJKArray *array, NSUInteger objectIndex) {
  NSCParameterAssert((array != NULL) && (array->objects != NULL) && (array->count <= array->capacity) && (objectIndex < array->count) && (array->objects[objectIndex] != NULL));
  if(!((array != NULL) && (array->objects != NULL) && (objectIndex < array->count) && (array->objects[objectIndex] != NULL))) { return; }
  CFRelease(array->objects[objectIndex]);
  array->objects[objectIndex] = NULL;
  if((objectIndex + 1UL) < array->count) { memmove(&array->objects[objectIndex], &array->objects[objectIndex + 1UL], sizeof(id) * ((array->count - 1UL) - objectIndex)); array->objects[array->count] = NULL; }
  array->count--;
}

- (void)dealloc
{
  if(SGJK_EXPECT_T(objects != NULL)) {
    NSUInteger atObject = 0UL;
    for(atObject = 0UL; atObject < count; atObject++) { if(SGJK_EXPECT_T(objects[atObject] != NULL)) { CFRelease(objects[atObject]); objects[atObject] = NULL; } }
    free(objects); objects = NULL;
  }
  
  [super dealloc];
}

- (NSUInteger)count
{
  NSParameterAssert((objects != NULL) && (count <= capacity));
  return(count);
}

- (void)getObjects:(id *)objectsPtr range:(NSRange)range
{
  NSParameterAssert((objects != NULL) && (count <= capacity));
  if((objectsPtr     == NULL)  && (NSMaxRange(range) > 0UL))   { [NSException raise:NSRangeException format:@"*** -[%@ %@]: pointer to objects array is NULL but range length is %lu", NSStringFromClass([self class]), NSStringFromSelector(_cmd), NSMaxRange(range)];        }
  if((range.location >  count) || (NSMaxRange(range) > count)) { [NSException raise:NSRangeException format:@"*** -[%@ %@]: index (%lu) beyond bounds (%lu)",                          NSStringFromClass([self class]), NSStringFromSelector(_cmd), NSMaxRange(range), count]; }
  memcpy(objectsPtr, objects + range.location, range.length * sizeof(id));
}

- (id)objectAtIndex:(NSUInteger)objectIndex
{
  if(objectIndex >= count) { [NSException raise:NSRangeException format:@"*** -[%@ %@]: index (%lu) beyond bounds (%lu)", NSStringFromClass([self class]), NSStringFromSelector(_cmd), objectIndex, count]; }
  NSParameterAssert((objects != NULL) && (count <= capacity) && (objects[objectIndex] != NULL));
  return(objects[objectIndex]);
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id *)stackbuf count:(NSUInteger)len
{
  NSParameterAssert((state != NULL) && (stackbuf != NULL) && (len > 0UL) && (objects != NULL) && (count <= capacity));
  if(SGJK_EXPECT_F(state->state == 0UL))   { state->mutationsPtr = (unsigned long *)&mutations; state->itemsPtr = stackbuf; }
  if(SGJK_EXPECT_F(state->state >= count)) { return(0UL); }
  
  NSUInteger enumeratedCount  = 0UL;
  while(SGJK_EXPECT_T(enumeratedCount < len) && SGJK_EXPECT_T(state->state < count)) { NSParameterAssert(objects[state->state] != NULL); stackbuf[enumeratedCount++] = objects[state->state++]; }
  
  return(enumeratedCount);
}

- (void)insertObject:(id)anObject atIndex:(NSUInteger)objectIndex
{
  if(mutations   == 0UL)   { [NSException raise:NSInternalInconsistencyException format:@"*** -[%@ %@]: mutating method sent to immutable object", NSStringFromClass([self class]), NSStringFromSelector(_cmd)]; }
  if(anObject    == NULL)  { [NSException raise:NSInvalidArgumentException       format:@"*** -[%@ %@]: attempt to insert nil",                    NSStringFromClass([self class]), NSStringFromSelector(_cmd)]; }
  if(objectIndex >  count) { [NSException raise:NSRangeException                 format:@"*** -[%@ %@]: index (%lu) beyond bounds (%lu)",          NSStringFromClass([self class]), NSStringFromSelector(_cmd), objectIndex, count + 1UL]; }
#ifdef __clang_analyzer__
  [anObject retain]; // Stupid clang analyzer...  Issue #19.
#else
  anObject = [anObject retain];
#endif
  _SGJKArrayInsertObjectAtIndex(self, anObject, objectIndex);
  mutations = (mutations == NSUIntegerMax) ? 1UL : mutations + 1UL;
}

- (void)removeObjectAtIndex:(NSUInteger)objectIndex
{
  if(mutations   == 0UL)   { [NSException raise:NSInternalInconsistencyException format:@"*** -[%@ %@]: mutating method sent to immutable object", NSStringFromClass([self class]), NSStringFromSelector(_cmd)]; }
  if(objectIndex >= count) { [NSException raise:NSRangeException                 format:@"*** -[%@ %@]: index (%lu) beyond bounds (%lu)",          NSStringFromClass([self class]), NSStringFromSelector(_cmd), objectIndex, count]; }
  _SGJKArrayRemoveObjectAtIndex(self, objectIndex);
  mutations = (mutations == NSUIntegerMax) ? 1UL : mutations + 1UL;
}

- (void)replaceObjectAtIndex:(NSUInteger)objectIndex withObject:(id)anObject
{
  if(mutations   == 0UL)   { [NSException raise:NSInternalInconsistencyException format:@"*** -[%@ %@]: mutating method sent to immutable object", NSStringFromClass([self class]), NSStringFromSelector(_cmd)]; }
  if(anObject    == NULL)  { [NSException raise:NSInvalidArgumentException       format:@"*** -[%@ %@]: attempt to insert nil",                    NSStringFromClass([self class]), NSStringFromSelector(_cmd)]; }
  if(objectIndex >= count) { [NSException raise:NSRangeException                 format:@"*** -[%@ %@]: index (%lu) beyond bounds (%lu)",          NSStringFromClass([self class]), NSStringFromSelector(_cmd), objectIndex, count]; }
#ifdef __clang_analyzer__
  [anObject retain]; // Stupid clang analyzer...  Issue #19.
#else
  anObject = [anObject retain];
#endif
  _SGJKArrayReplaceObjectAtIndexWithObject(self, objectIndex, anObject);
  mutations = (mutations == NSUIntegerMax) ? 1UL : mutations + 1UL;
}

- (id)copyWithZone:(NSZone *)zone
{
  NSParameterAssert((objects != NULL) && (count <= capacity));
  return((mutations == 0UL) ? [self retain] : [[NSArray allocWithZone:zone] initWithObjects:objects count:count]);
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
  NSParameterAssert((objects != NULL) && (count <= capacity));
  return([[NSMutableArray allocWithZone:zone] initWithObjects:objects count:count]);
}

@end


#pragma mark -
@interface SGJKDictionaryEnumerator : NSEnumerator {
  id         collection;
  NSUInteger nextObject;
}

- (id)initWithSGJKDictionary:(SGJKDictionary *)initDictionary;
- (NSArray *)allObjects;
- (id)nextObject;

@end

@implementation SGJKDictionaryEnumerator

- (id)initWithSGJKDictionary:(SGJKDictionary *)initDictionary
{
  NSParameterAssert(initDictionary != NULL);
  if((self = [super init]) == NULL) { return(NULL); }
  if((collection = (id)CFRetain(initDictionary)) == NULL) { [self autorelease]; return(NULL); }
  return(self);
}

- (void)dealloc
{
  if(collection != NULL) { CFRelease(collection); collection = NULL; }
  [super dealloc];
}

- (NSArray *)allObjects
{
  NSParameterAssert(collection != NULL);
  NSUInteger count = [collection count], atObject = 0UL;
  id         objects[count];

  while((objects[atObject] = [self nextObject]) != NULL) { NSParameterAssert(atObject < count); atObject++; }

  return([NSArray arrayWithObjects:objects count:atObject]);
}

- (id)nextObject
{
  NSParameterAssert((collection != NULL) && (_SGJKDictionaryHashEntry(collection) != NULL));
  SGJKHashTableEntry *entry        = _SGJKDictionaryHashEntry(collection);
  NSUInteger        capacity     = _SGJKDictionaryCapacity(collection);
  id                returnObject = NULL;

  if(entry != NULL) { while((nextObject < capacity) && ((returnObject = entry[nextObject++].key) == NULL)) { /* ... */ } }
  
  return(returnObject);
}

@end

#pragma mark -
@interface SGJKDictionary : NSMutableDictionary <NSCopying, NSMutableCopying, NSFastEnumeration> {
  NSUInteger count, capacity, mutations;
  SGJKHashTableEntry *entry;
}
@end

@implementation SGJKDictionary

+ (id)allocWithZone:(NSZone *)zone
{
#pragma unused(zone)
  [NSException raise:NSInvalidArgumentException format:@"*** - [%@ %@]: The %@ class is private to JSONKit and should not be used in this fashion.", NSStringFromClass([self class]), NSStringFromSelector(_cmd), NSStringFromClass([self class])];
  return(NULL);
}

// These values are taken from Core Foundation CF-550 CFBSGASIcHash.m.  As a bonus, they align very well with our SGJKHashTableEntry struct too.
static const NSUInteger SGJK_dictionaryCapacities[] = {
  0UL, 3UL, 7UL, 13UL, 23UL, 41UL, 71UL, 127UL, 191UL, 251UL, 383UL, 631UL, 1087UL, 1723UL,
  2803UL, 4523UL, 7351UL, 11959UL, 19447UL, 31231UL, 50683UL, 81919UL, 132607UL,
  214519UL, 346607UL, 561109UL, 907759UL, 1468927UL, 2376191UL, 3845119UL,
  6221311UL, 10066421UL, 16287743UL, 26354171UL, 42641881UL, 68996069UL,
  111638519UL, 180634607UL, 292272623UL, 472907251UL
};

static NSUInteger _SGJKDictionaryCapacityForCount(NSUInteger count) {
  NSUInteger bottom = 0UL, top = sizeof(SGJK_dictionaryCapacities) / sizeof(NSUInteger), mid = 0UL, tableSize = lround(floor((count) * 1.33));
  while(top > bottom) { mid = (top + bottom) / 2UL; if(SGJK_dictionaryCapacities[mid] < tableSize) { bottom = mid + 1UL; } else { top = mid; } }
  return(SGJK_dictionaryCapacities[bottom]);
}

static void _SGJKDictionaryResizeIfNeccessary(SGJKDictionary *dictionary) {
  NSCParameterAssert((dictionary != NULL) && (dictionary->entry != NULL) && (dictionary->count <= dictionary->capacity));

  NSUInteger capacityForCount = 0UL;
  if(dictionary->capacity < (capacityForCount = _SGJKDictionaryCapacityForCount(dictionary->count + 1UL))) { // resize
    NSUInteger        oldCapacity = dictionary->capacity;
#ifndef NS_BLOCK_ASSERTIONS
    NSUInteger oldCount = dictionary->count;
#endif
    SGJKHashTableEntry *oldEntry    = dictionary->entry;
    if(SGJK_EXPECT_F((dictionary->entry = (SGJKHashTableEntry *)calloc(1UL, sizeof(SGJKHashTableEntry) * capacityForCount)) == NULL)) { [NSException raise:NSMallocException format:@"Unable to allocate memory for hash table."]; }
    dictionary->capacity = capacityForCount;
    dictionary->count    = 0UL;
    
    NSUInteger idx = 0UL;
    for(idx = 0UL; idx < oldCapacity; idx++) { if(oldEntry[idx].key != NULL) { _SGJKDictionaryAddObject(dictionary, oldEntry[idx].keyHash, oldEntry[idx].key, oldEntry[idx].object); oldEntry[idx].keyHash = 0UL; oldEntry[idx].key = NULL; oldEntry[idx].object = NULL; } }
    NSCParameterAssert((oldCount == dictionary->count));
    free(oldEntry); oldEntry = NULL;
  }
}

static SGJKDictionary *_SGJKDictionaryCreate(id *keys, NSUInteger *keyHashes, id *objects, NSUInteger count, BOOL mutableCollection) {
  NSCParameterAssert((keys != NULL) && (keyHashes != NULL) && (objects != NULL) && (_SGJKDictionaryClass != NULL) && (_SGJKDictionaryInstanceSize > 0UL));
  SGJKDictionary *dictionary = NULL;
  if(SGJK_EXPECT_T((dictionary = (SGJKDictionary *)calloc(1UL, _SGJKDictionaryInstanceSize)) != NULL)) { // Directly allocate the SGJKDictionary instance via calloc.
    dictionary->isa      = _SGJKDictionaryClass;
    if((dictionary = [dictionary init]) == NULL) { return(NULL); }
    dictionary->capacity = _SGJKDictionaryCapacityForCount(count);
    dictionary->count    = 0UL;
    
    if(SGJK_EXPECT_F((dictionary->entry = (SGJKHashTableEntry *)calloc(1UL, sizeof(SGJKHashTableEntry) * dictionary->capacity)) == NULL)) { [dictionary autorelease]; return(NULL); }

    NSUInteger idx = 0UL;
    for(idx = 0UL; idx < count; idx++) { _SGJKDictionaryAddObject(dictionary, keyHashes[idx], keys[idx], objects[idx]); }

    dictionary->mutations = (mutableCollection == NO) ? 0UL : 1UL;
  }
  return(dictionary);
}

- (void)dealloc
{
  if(SGJK_EXPECT_T(entry != NULL)) {
    NSUInteger atEntry = 0UL;
    for(atEntry = 0UL; atEntry < capacity; atEntry++) {
      if(SGJK_EXPECT_T(entry[atEntry].key    != NULL)) { CFRelease(entry[atEntry].key);    entry[atEntry].key    = NULL; }
      if(SGJK_EXPECT_T(entry[atEntry].object != NULL)) { CFRelease(entry[atEntry].object); entry[atEntry].object = NULL; }
    }
  
    free(entry); entry = NULL;
  }

  [super dealloc];
}

static SGJKHashTableEntry *_SGJKDictionaryHashEntry(SGJKDictionary *dictionary) {
  NSCParameterAssert(dictionary != NULL);
  return(dictionary->entry);
}

static NSUInteger _SGJKDictionaryCapacity(SGJKDictionary *dictionary) {
  NSCParameterAssert(dictionary != NULL);
  return(dictionary->capacity);
}

static void _SGJKDictionaryRemoveObjectWithEntry(SGJKDictionary *dictionary, SGJKHashTableEntry *entry) {
  NSCParameterAssert((dictionary != NULL) && (entry != NULL) && (entry->key != NULL) && (entry->object != NULL) && (dictionary->count > 0UL) && (dictionary->count <= dictionary->capacity));
  CFRelease(entry->key);    entry->key    = NULL;
  CFRelease(entry->object); entry->object = NULL;
  entry->keyHash = 0UL;
  dictionary->count--;
  // In order for certain invariants that are used to speed up the search for a particular key, we need to "re-add" all the entries in the hash table following this entry until we hit a NULL entry.
  NSUInteger removeIdx = entry - dictionary->entry, idx = 0UL;
  NSCParameterAssert((removeIdx < dictionary->capacity));
  for(idx = 0UL; idx < dictionary->capacity; idx++) {
    NSUInteger entryIdx = (removeIdx + idx + 1UL) % dictionary->capacity;
    SGJKHashTableEntry *atEntry = &dictionary->entry[entryIdx];
    if(atEntry->key == NULL) { break; }
    NSUInteger keyHash = atEntry->keyHash;
    id key = atEntry->key, object = atEntry->object;
    NSCParameterAssert(object != NULL);
    atEntry->keyHash = 0UL;
    atEntry->key     = NULL;
    atEntry->object  = NULL;
    NSUInteger addKeyEntry = keyHash % dictionary->capacity, addIdx = 0UL;
    for(addIdx = 0UL; addIdx < dictionary->capacity; addIdx++) {
      SGJKHashTableEntry *atAddEntry = &dictionary->entry[((addKeyEntry + addIdx) % dictionary->capacity)];
      if(SGJK_EXPECT_T(atAddEntry->key == NULL)) { NSCParameterAssert((atAddEntry->keyHash == 0UL) && (atAddEntry->object == NULL)); atAddEntry->key = key; atAddEntry->object = object; atAddEntry->keyHash = keyHash; break; }
    }
  }
}

static void _SGJKDictionaryAddObject(SGJKDictionary *dictionary, NSUInteger keyHash, id key, id object) {
  NSCParameterAssert((dictionary != NULL) && (key != NULL) && (object != NULL) && (dictionary->count < dictionary->capacity) && (dictionary->entry != NULL));
  NSUInteger keyEntry = keyHash % dictionary->capacity, idx = 0UL;
  for(idx = 0UL; idx < dictionary->capacity; idx++) {
    NSUInteger entryIdx = (keyEntry + idx) % dictionary->capacity;
    SGJKHashTableEntry *atEntry = &dictionary->entry[entryIdx];
    if(SGJK_EXPECT_F(atEntry->keyHash == keyHash) && SGJK_EXPECT_T(atEntry->key != NULL) && (SGJK_EXPECT_F(key == atEntry->key) || SGJK_EXPECT_F(CFEqual(atEntry->key, key)))) { _SGJKDictionaryRemoveObjectWithEntry(dictionary, atEntry); }
    if(SGJK_EXPECT_T(atEntry->key == NULL)) { NSCParameterAssert((atEntry->keyHash == 0UL) && (atEntry->object == NULL)); atEntry->key = key; atEntry->object = object; atEntry->keyHash = keyHash; dictionary->count++; return; }
  }

  // We should never get here.  If we do, we -release the key / object because it's our responsibility.
  CFRelease(key);
  CFRelease(object);
}

- (NSUInteger)count
{
  return(count);
}

static SGJKHashTableEntry *_SGJKDictionaryHashTableEntryForKey(SGJKDictionary *dictionary, id aKey) {
  NSCParameterAssert((dictionary != NULL) && (dictionary->entry != NULL) && (dictionary->count <= dictionary->capacity));
  if((aKey == NULL) || (dictionary->capacity == 0UL)) { return(NULL); }
  NSUInteger        keyHash = CFHash(aKey), keyEntry = (keyHash % dictionary->capacity), idx = 0UL;
  SGJKHashTableEntry *atEntry = NULL;
  for(idx = 0UL; idx < dictionary->capacity; idx++) {
    atEntry = &dictionary->entry[(keyEntry + idx) % dictionary->capacity];
    if(SGJK_EXPECT_T(atEntry->keyHash == keyHash) && SGJK_EXPECT_T(atEntry->key != NULL) && ((atEntry->key == aKey) || CFEqual(atEntry->key, aKey))) { NSCParameterAssert(atEntry->object != NULL); return(atEntry); break; }
    if(SGJK_EXPECT_F(atEntry->key == NULL)) { NSCParameterAssert(atEntry->object == NULL); return(NULL); break; } // If the key was in the table, we would have found it by now.
  }
  return(NULL);
}

- (id)objectForKey:(id)aKey
{
  NSParameterAssert((entry != NULL) && (count <= capacity));
  SGJKHashTableEntry *entryForKey = _SGJKDictionaryHashTableEntryForKey(self, aKey);
  return((entryForKey != NULL) ? entryForKey->object : NULL);
}

- (void)getObjects:(id *)objects andKeys:(id *)keys
{
  NSParameterAssert((entry != NULL) && (count <= capacity));
  NSUInteger atEntry = 0UL; NSUInteger arrayIdx = 0UL;
  for(atEntry = 0UL; atEntry < capacity; atEntry++) {
    if(SGJK_EXPECT_T(entry[atEntry].key != NULL)) {
      NSCParameterAssert((entry[atEntry].object != NULL) && (arrayIdx < count));
      if(SGJK_EXPECT_T(keys    != NULL)) { keys[arrayIdx]    = entry[atEntry].key;    }
      if(SGJK_EXPECT_T(objects != NULL)) { objects[arrayIdx] = entry[atEntry].object; }
      arrayIdx++;
    }
  }
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id *)stackbuf count:(NSUInteger)len
{
  NSParameterAssert((state != NULL) && (stackbuf != NULL) && (len > 0UL) && (entry != NULL) && (count <= capacity));
  if(SGJK_EXPECT_F(state->state == 0UL))      { state->mutationsPtr = (unsigned long *)&mutations; state->itemsPtr = stackbuf; }
  if(SGJK_EXPECT_F(state->state >= capacity)) { return(0UL); }
  
  NSUInteger enumeratedCount  = 0UL;
  while(SGJK_EXPECT_T(enumeratedCount < len) && SGJK_EXPECT_T(state->state < capacity)) { if(SGJK_EXPECT_T(entry[state->state].key != NULL)) { stackbuf[enumeratedCount++] = entry[state->state].key; } state->state++; }
    
  return(enumeratedCount);
}

- (NSEnumerator *)keyEnumerator
{
  return([[[SGJKDictionaryEnumerator alloc] initWithSGJKDictionary:self] autorelease]);
}

- (void)setObject:(id)anObject forKey:(id)aKey
{
  if(mutations == 0UL)  { [NSException raise:NSInternalInconsistencyException format:@"*** -[%@ %@]: mutating method sent to immutable object", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];       }
  if(aKey      == NULL) { [NSException raise:NSInvalidArgumentException       format:@"*** -[%@ %@]: attempt to insert nil key",                NSStringFromClass([self class]), NSStringFromSelector(_cmd)];       }
  if(anObject  == NULL) { [NSException raise:NSInvalidArgumentException       format:@"*** -[%@ %@]: attempt to insert nil value (key: %@)",    NSStringFromClass([self class]), NSStringFromSelector(_cmd), aKey]; }
  
  _SGJKDictionaryResizeIfNeccessary(self);
#ifndef __clang_analyzer__
  aKey     = [aKey     copy];   // Why on earth would clang complain that this -copy "might leak", 
  anObject = [anObject retain]; // but this -retain doesn't!?
#endif // __clang_analyzer__
  _SGJKDictionaryAddObject(self, CFHash(aKey), aKey, anObject);
  mutations = (mutations == NSUIntegerMax) ? 1UL : mutations + 1UL;
}

- (void)removeObjectForKey:(id)aKey
{
  if(mutations == 0UL)  { [NSException raise:NSInternalInconsistencyException format:@"*** -[%@ %@]: mutating method sent to immutable object", NSStringFromClass([self class]), NSStringFromSelector(_cmd)]; }
  if(aKey      == NULL) { [NSException raise:NSInvalidArgumentException       format:@"*** -[%@ %@]: attempt to remove nil key",                NSStringFromClass([self class]), NSStringFromSelector(_cmd)]; }
  SGJKHashTableEntry *entryForKey = _SGJKDictionaryHashTableEntryForKey(self, aKey);
  if(entryForKey != NULL) {
    _SGJKDictionaryRemoveObjectWithEntry(self, entryForKey);
    mutations = (mutations == NSUIntegerMax) ? 1UL : mutations + 1UL;
  }
}

- (id)copyWithZone:(NSZone *)zone
{
  NSParameterAssert((entry != NULL) && (count <= capacity));
  return((mutations == 0UL) ? [self retain] : [[NSDictionary allocWithZone:zone] initWithDictionary:self]);
}

- (id)mutableCopyWithZone:(NSZone *)zone
{
  NSParameterAssert((entry != NULL) && (count <= capacity));
  return([[NSMutableDictionary allocWithZone:zone] initWithDictionary:self]);
}

@end



#pragma mark -

SGJK_STATIC_INLINE size_t SGJK_min(size_t a, size_t b) { return((a < b) ? a : b); }
SGJK_STATIC_INLINE size_t SGJK_max(size_t a, size_t b) { return((a > b) ? a : b); }

SGJK_STATIC_INLINE SGJKHash calculateHash(SGJKHash currentHash, unsigned char c) { return(((currentHash << 5) + currentHash) + c); }

static void SGJK_error(SGJKParseState *parseState, NSString *format, ...) {
  NSCParameterAssert((parseState != NULL) && (format != NULL));

  va_list varArgsList;
  va_start(varArgsList, format);
  NSString *formatString = [[[NSString alloc] initWithFormat:format arguments:varArgsList] autorelease];
  va_end(varArgsList);

#if 0
  const unsigned char *lineStart      = parseState->stringBuffer.bytes.ptr + parseState->lineStartIndex;
  const unsigned char *lineEnd        = lineStart;
  const unsigned char *atCharacterPtr = NULL;

  for(atCharacterPtr = lineStart; atCharacterPtr < SGJK_END_STRING_PTR(parseState); atCharacterPtr++) { lineEnd = atCharacterPtr; if(SGJK_parse_is_newline(parseState, atCharacterPtr)) { break; } }

  NSString *lineString = @"", *carretString = @"";
  if(lineStart < SGJK_END_STRING_PTR(parseState)) {
    lineString   = [[[NSString alloc] initWithBytes:lineStart length:(lineEnd - lineStart) encoding:NSUTF8StringEncoding] autorelease];
    carretString = [NSString stringWithFormat:@"%*.*s^", (int)(parseState->atIndex - parseState->lineStartIndex), (int)(parseState->atIndex - parseState->lineStartIndex), " "];
  }
#endif

  if(parseState->error == NULL) {
    parseState->error = [NSError errorWithDomain:@"SGJKErrorDomain" code:-1L userInfo:
                                   [NSDictionary dictionaryWithObjectsAndKeys:
                                                                              formatString,                                             NSLocalizedDescriptionKey,
                                                                              [NSNumber numberWithUnsignedLong:parseState->atIndex],    @"SGJKAtIndexKey",
                                                                              [NSNumber numberWithUnsignedLong:parseState->lineNumber], @"SGJKLineNumberKey",
                                                 //lineString,   @"SGJKErrorLine0Key",
                                                 //carretString, @"SGJKErrorLine1Key",
                                                                              NULL]];
  }
}

#pragma mark -
#pragma mark Buffer and Object Stack management functions

static void SGJK_managedBuffer_release(SGJKManagedBuffer *managedBuffer) {
  if((managedBuffer->flags & SGJKManagedBufferMustFree)) {
    if(managedBuffer->bytes.ptr != NULL) { free(managedBuffer->bytes.ptr); managedBuffer->bytes.ptr = NULL; }
    managedBuffer->flags &= ~SGJKManagedBufferMustFree;
  }

  managedBuffer->bytes.ptr     = NULL;
  managedBuffer->bytes.length  = 0UL;
  managedBuffer->flags        &= ~SGJKManagedBufferLocationMask;
}

static void SGJK_managedBuffer_setToStackBuffer(SGJKManagedBuffer *managedBuffer, unsigned char *ptr, size_t length) {
  SGJK_managedBuffer_release(managedBuffer);
  managedBuffer->bytes.ptr     = ptr;
  managedBuffer->bytes.length  = length;
  managedBuffer->flags         = (managedBuffer->flags & ~SGJKManagedBufferLocationMask) | SGJKManagedBufferOnStack;
}

static unsigned char *SGJK_managedBuffer_resize(SGJKManagedBuffer *managedBuffer, size_t newSize) {
  size_t roundedUpNewSize = newSize;

  if(managedBuffer->roundSizeUpToMultipleOf > 0UL) { roundedUpNewSize = newSize + ((managedBuffer->roundSizeUpToMultipleOf - (newSize % managedBuffer->roundSizeUpToMultipleOf)) % managedBuffer->roundSizeUpToMultipleOf); }

  if((roundedUpNewSize != managedBuffer->bytes.length) && (roundedUpNewSize > managedBuffer->bytes.length)) {
    if((managedBuffer->flags & SGJKManagedBufferLocationMask) == SGJKManagedBufferOnStack) {
      NSCParameterAssert((managedBuffer->flags & SGJKManagedBufferMustFree) == 0);
      unsigned char *newBuffer = NULL, *oldBuffer = managedBuffer->bytes.ptr;
      
      if((newBuffer = (unsigned char *)malloc(roundedUpNewSize)) == NULL) { return(NULL); }
      memcpy(newBuffer, oldBuffer, SGJK_min(managedBuffer->bytes.length, roundedUpNewSize));
      managedBuffer->flags        = (managedBuffer->flags & ~SGJKManagedBufferLocationMask) | (SGJKManagedBufferOnHeap | SGJKManagedBufferMustFree);
      managedBuffer->bytes.ptr    = newBuffer;
      managedBuffer->bytes.length = roundedUpNewSize;
    } else {
      NSCParameterAssert(((managedBuffer->flags & SGJKManagedBufferMustFree) != 0) && ((managedBuffer->flags & SGJKManagedBufferLocationMask) == SGJKManagedBufferOnHeap));
      if((managedBuffer->bytes.ptr = (unsigned char *)reallocf(managedBuffer->bytes.ptr, roundedUpNewSize)) == NULL) { return(NULL); }
      managedBuffer->bytes.length = roundedUpNewSize;
    }
  }

  return(managedBuffer->bytes.ptr);
}



static void SGJK_objectStack_release(SGJKObjectStack *objectStack) {
  NSCParameterAssert(objectStack != NULL);

  NSCParameterAssert(objectStack->index <= objectStack->count);
  size_t atIndex = 0UL;
  for(atIndex = 0UL; atIndex < objectStack->index; atIndex++) {
    if(objectStack->objects[atIndex] != NULL) { CFRelease(objectStack->objects[atIndex]); objectStack->objects[atIndex] = NULL; }
    if(objectStack->keys[atIndex]    != NULL) { CFRelease(objectStack->keys[atIndex]);    objectStack->keys[atIndex]    = NULL; }
  }
  objectStack->index = 0UL;

  if(objectStack->flags & SGJKObjectStackMustFree) {
    NSCParameterAssert((objectStack->flags & SGJKObjectStackLocationMask) == SGJKObjectStackOnHeap);
    if(objectStack->objects  != NULL) { free(objectStack->objects);  objectStack->objects  = NULL; }
    if(objectStack->keys     != NULL) { free(objectStack->keys);     objectStack->keys     = NULL; }
    if(objectStack->cfHashes != NULL) { free(objectStack->cfHashes); objectStack->cfHashes = NULL; }
    objectStack->flags &= ~SGJKObjectStackMustFree;
  }

  objectStack->objects  = NULL;
  objectStack->keys     = NULL;
  objectStack->cfHashes = NULL;

  objectStack->count    = 0UL;
  objectStack->flags   &= ~SGJKObjectStackLocationMask;
}

static void SGJK_objectStack_setToStackBuffer(SGJKObjectStack *objectStack, void **objects, void **keys, CFHashCode *cfHashes, size_t count) {
  NSCParameterAssert((objectStack != NULL) && (objects != NULL) && (keys != NULL) && (cfHashes != NULL) && (count > 0UL));
  SGJK_objectStack_release(objectStack);
  objectStack->objects  = objects;
  objectStack->keys     = keys;
  objectStack->cfHashes = cfHashes;
  objectStack->count    = count;
  objectStack->flags    = (objectStack->flags & ~SGJKObjectStackLocationMask) | SGJKObjectStackOnStack;
#ifndef NS_BLOCK_ASSERTIONS
  size_t idx;
  for(idx = 0UL; idx < objectStack->count; idx++) { objectStack->objects[idx] = NULL; objectStack->keys[idx] = NULL; objectStack->cfHashes[idx] = 0UL; }
#endif
}

static int SGJK_objectStack_resize(SGJKObjectStack *objectStack, size_t newCount) {
  size_t roundedUpNewCount = newCount;
  int    returnCode = 0;

  void       **newObjects  = NULL, **newKeys = NULL;
  CFHashCode  *newCFHashes = NULL;

  if(objectStack->roundSizeUpToMultipleOf > 0UL) { roundedUpNewCount = newCount + ((objectStack->roundSizeUpToMultipleOf - (newCount % objectStack->roundSizeUpToMultipleOf)) % objectStack->roundSizeUpToMultipleOf); }

  if((roundedUpNewCount != objectStack->count) && (roundedUpNewCount > objectStack->count)) {
    if((objectStack->flags & SGJKObjectStackLocationMask) == SGJKObjectStackOnStack) {
      NSCParameterAssert((objectStack->flags & SGJKObjectStackMustFree) == 0);

      if((newObjects  = (void **     )calloc(1UL, roundedUpNewCount * sizeof(void *    ))) == NULL) { returnCode = 1; goto errorExit; }
      memcpy(newObjects, objectStack->objects,   SGJK_min(objectStack->count, roundedUpNewCount) * sizeof(void *));
      if((newKeys     = (void **     )calloc(1UL, roundedUpNewCount * sizeof(void *    ))) == NULL) { returnCode = 1; goto errorExit; }
      memcpy(newKeys,     objectStack->keys,     SGJK_min(objectStack->count, roundedUpNewCount) * sizeof(void *));

      if((newCFHashes = (CFHashCode *)calloc(1UL, roundedUpNewCount * sizeof(CFHashCode))) == NULL) { returnCode = 1; goto errorExit; }
      memcpy(newCFHashes, objectStack->cfHashes, SGJK_min(objectStack->count, roundedUpNewCount) * sizeof(CFHashCode));

      objectStack->flags    = (objectStack->flags & ~SGJKObjectStackLocationMask) | (SGJKObjectStackOnHeap | SGJKObjectStackMustFree);
      objectStack->objects  = newObjects;  newObjects  = NULL;
      objectStack->keys     = newKeys;     newKeys     = NULL;
      objectStack->cfHashes = newCFHashes; newCFHashes = NULL;
      objectStack->count    = roundedUpNewCount;
    } else {
      NSCParameterAssert(((objectStack->flags & SGJKObjectStackMustFree) != 0) && ((objectStack->flags & SGJKObjectStackLocationMask) == SGJKObjectStackOnHeap));
      if((newObjects  = (void  **    )realloc(objectStack->objects,  roundedUpNewCount * sizeof(void *    ))) != NULL) { objectStack->objects  = newObjects;  newObjects  = NULL; } else { returnCode = 1; goto errorExit; }
      if((newKeys     = (void  **    )realloc(objectStack->keys,     roundedUpNewCount * sizeof(void *    ))) != NULL) { objectStack->keys     = newKeys;     newKeys     = NULL; } else { returnCode = 1; goto errorExit; }
      if((newCFHashes = (CFHashCode *)realloc(objectStack->cfHashes, roundedUpNewCount * sizeof(CFHashCode))) != NULL) { objectStack->cfHashes = newCFHashes; newCFHashes = NULL; } else { returnCode = 1; goto errorExit; }

#ifndef NS_BLOCK_ASSERTIONS
      size_t idx;
      for(idx = objectStack->count; idx < roundedUpNewCount; idx++) { objectStack->objects[idx] = NULL; objectStack->keys[idx] = NULL; objectStack->cfHashes[idx] = 0UL; }
#endif
      objectStack->count = roundedUpNewCount;
    }
  }

 errorExit:
  if(newObjects  != NULL) { free(newObjects);  newObjects  = NULL; }
  if(newKeys     != NULL) { free(newKeys);     newKeys     = NULL; }
  if(newCFHashes != NULL) { free(newCFHashes); newCFHashes = NULL; }

  return(returnCode);
}

////////////
#pragma mark -
#pragma mark Unicode related functions

SGJK_STATIC_INLINE ConversionResult isValidCodePoint(UTF32 *u32CodePoint) {
  ConversionResult result = conversionOK;
  UTF32            ch     = *u32CodePoint;

  if(SGJK_EXPECT_F(ch >= UNI_SUR_HIGH_START) && (SGJK_EXPECT_T(ch <= UNI_SUR_LOW_END)))                                                        { result = sourceIllegal; ch = UNI_REPLACEMENT_CHAR; goto finished; }
  if(SGJK_EXPECT_F(ch >= 0xFDD0U) && (SGJK_EXPECT_F(ch <= 0xFDEFU) || SGJK_EXPECT_F((ch & 0xFFFEU) == 0xFFFEU)) && SGJK_EXPECT_T(ch <= 0x10FFFFU)) { result = sourceIllegal; ch = UNI_REPLACEMENT_CHAR; goto finished; }
  if(SGJK_EXPECT_F(ch == 0U))                                                                                                                { result = sourceIllegal; ch = UNI_REPLACEMENT_CHAR; goto finished; }

 finished:
  *u32CodePoint = ch;
  return(result);
}


static int isLegalUTF8(const UTF8 *source, size_t length) {
  const UTF8 *srcptr = source + length;
  UTF8 a;

  switch(length) {
    default: return(0); // Everything else falls through when "true"...
    case 4: if(SGJK_EXPECT_F(((a = (*--srcptr)) < 0x80) || (a > 0xBF))) { return(0); }
    case 3: if(SGJK_EXPECT_F(((a = (*--srcptr)) < 0x80) || (a > 0xBF))) { return(0); }
    case 2: if(SGJK_EXPECT_F( (a = (*--srcptr)) > 0xBF               )) { return(0); }
      
      switch(*source) { // no fall-through in this inner switch
        case 0xE0: if(SGJK_EXPECT_F(a < 0xA0)) { return(0); } break;
        case 0xED: if(SGJK_EXPECT_F(a > 0x9F)) { return(0); } break;
        case 0xF0: if(SGJK_EXPECT_F(a < 0x90)) { return(0); } break;
        case 0xF4: if(SGJK_EXPECT_F(a > 0x8F)) { return(0); } break;
        default:   if(SGJK_EXPECT_F(a < 0x80)) { return(0); }
      }
      
    case 1: if(SGJK_EXPECT_F((SGJK_EXPECT_T(*source < 0xC2)) && SGJK_EXPECT_F(*source >= 0x80))) { return(0); }
  }

  if(SGJK_EXPECT_F(*source > 0xF4)) { return(0); }

  return(1);
}

static ConversionResult ConvertSingleCodePointInUTF8(const UTF8 *sourceStart, const UTF8 *sourceEnd, UTF8 const **nextUTF8, UTF32 *convertedUTF32) {
  ConversionResult result = conversionOK;
  const UTF8 *source = sourceStart;
  UTF32 ch = 0UL;

#if !defined(SGJK_FAST_TRAILING_BYTES)
  unsigned short extraBytesToRead = trailingBytesForUTF8[*source];
#else
  unsigned short extraBytesToRead = __builtin_clz(((*source)^0xff) << 25);
#endif

  if(SGJK_EXPECT_F((source + extraBytesToRead + 1) > sourceEnd) || SGJK_EXPECT_F(!isLegalUTF8(source, extraBytesToRead + 1))) {
    source++;
    while((source < sourceEnd) && (((*source) & 0xc0) == 0x80) && ((source - sourceStart) < (extraBytesToRead + 1))) { source++; } 
    NSCParameterAssert(source <= sourceEnd);
    result = ((source < sourceEnd) && (((*source) & 0xc0) != 0x80)) ? sourceIllegal : ((sourceStart + extraBytesToRead + 1) > sourceEnd) ? sourceExhausted : sourceIllegal;
    ch = UNI_REPLACEMENT_CHAR;
    goto finished;
  }

  switch(extraBytesToRead) { // The cases all fall through.
    case 5: ch += *source++; ch <<= 6;
    case 4: ch += *source++; ch <<= 6;
    case 3: ch += *source++; ch <<= 6;
    case 2: ch += *source++; ch <<= 6;
    case 1: ch += *source++; ch <<= 6;
    case 0: ch += *source++;
  }
  ch -= offsetsFromUTF8[extraBytesToRead];

  result = isValidCodePoint(&ch);
  
 finished:
  *nextUTF8       = source;
  *convertedUTF32 = ch;
  
  return(result);
}


static ConversionResult ConvertUTF32toUTF8 (UTF32 u32CodePoint, UTF8 **targetStart, UTF8 *targetEnd) {
  const UTF32       byteMask     = 0xBF, byteMark = 0x80;
  ConversionResult  result       = conversionOK;
  UTF8             *target       = *targetStart;
  UTF32             ch           = u32CodePoint;
  unsigned short    bytesToWrite = 0;

  result = isValidCodePoint(&ch);

  // Figure out how many bytes the result will require. Turn any illegally large UTF32 things (> Plane 17) into replacement chars.
       if(ch < (UTF32)0x80)          { bytesToWrite = 1; }
  else if(ch < (UTF32)0x800)         { bytesToWrite = 2; }
  else if(ch < (UTF32)0x10000)       { bytesToWrite = 3; }
  else if(ch <= UNI_MAX_LEGAL_UTF32) { bytesToWrite = 4; }
  else {                               bytesToWrite = 3; ch = UNI_REPLACEMENT_CHAR; result = sourceIllegal; }
        
  target += bytesToWrite;
  if (target > targetEnd) { target -= bytesToWrite; result = targetExhausted; goto finished; }

  switch (bytesToWrite) { // note: everything falls through.
    case 4: *--target = (UTF8)((ch | byteMark) & byteMask); ch >>= 6;
    case 3: *--target = (UTF8)((ch | byteMark) & byteMask); ch >>= 6;
    case 2: *--target = (UTF8)((ch | byteMark) & byteMask); ch >>= 6;
    case 1: *--target = (UTF8) (ch | firstByteMark[bytesToWrite]);
  }

  target += bytesToWrite;

 finished:
  *targetStart = target;
  return(result);
}

SGJK_STATIC_INLINE int SGJK_string_add_unicodeCodePoint(SGJKParseState *parseState, uint32_t unicodeCodePoint, size_t *tokenBufferIdx, SGJKHash *stringHash) {
  UTF8             *u8s = &parseState->token.tokenBuffer.bytes.ptr[*tokenBufferIdx];
  ConversionResult  result;

  if((result = ConvertUTF32toUTF8(unicodeCodePoint, &u8s, (parseState->token.tokenBuffer.bytes.ptr + parseState->token.tokenBuffer.bytes.length))) != conversionOK) { if(result == targetExhausted) { return(1); } }
  size_t utf8len = u8s - &parseState->token.tokenBuffer.bytes.ptr[*tokenBufferIdx], nextIdx = (*tokenBufferIdx) + utf8len;
  
  while(*tokenBufferIdx < nextIdx) { *stringHash = calculateHash(*stringHash, parseState->token.tokenBuffer.bytes.ptr[(*tokenBufferIdx)++]); }

  return(0);
}

////////////
#pragma mark -
#pragma mark Decoding / parsing / deserializing functions

static int SGJK_parse_string(SGJKParseState *parseState) {
  NSCParameterAssert((parseState != NULL) && (SGJK_AT_STRING_PTR(parseState) <= SGJK_END_STRING_PTR(parseState)));
  const unsigned char *stringStart       = SGJK_AT_STRING_PTR(parseState) + 1;
  const unsigned char *endOfBuffer       = SGJK_END_STRING_PTR(parseState);
  const unsigned char *atStringCharacter = stringStart;
  unsigned char       *tokenBuffer       = parseState->token.tokenBuffer.bytes.ptr;
  size_t               tokenStartIndex   = parseState->atIndex;
  size_t               tokenBufferIdx    = 0UL;

  int      onlySimpleString        = 1,  stringState     = JSONStringStateStart;
  uint16_t escapedUnicode1         = 0U, escapedUnicode2 = 0U;
  uint32_t escapedUnicodeCodePoint = 0U;
  SGJKHash   stringHash              = SGJK_HASH_INIT;
    
  while(1) {
    unsigned long currentChar;

    if(SGJK_EXPECT_F(atStringCharacter == endOfBuffer)) { /* XXX Add error message */ stringState = JSONStringStateError; goto finishedParsing; }
    
    if(SGJK_EXPECT_F((currentChar = *atStringCharacter++) >= 0x80UL)) {
      const unsigned char *nextValidCharacter = NULL;
      UTF32                u32ch              = 0U;
      ConversionResult     result;

      if(SGJK_EXPECT_F((result = ConvertSingleCodePointInUTF8(atStringCharacter - 1, endOfBuffer, (UTF8 const **)&nextValidCharacter, &u32ch)) != conversionOK)) { goto switchToSlowPath; }
      stringHash = calculateHash(stringHash, currentChar);
      while(atStringCharacter < nextValidCharacter) { NSCParameterAssert(SGJK_AT_STRING_PTR(parseState) <= SGJK_END_STRING_PTR(parseState)); stringHash = calculateHash(stringHash, *atStringCharacter++); }
      continue;
    } else {
      if(SGJK_EXPECT_F(currentChar == (unsigned long)'"')) { stringState = JSONStringStateFinished; goto finishedParsing; }

      if(SGJK_EXPECT_F(currentChar == (unsigned long)'\\')) {
      switchToSlowPath:
        onlySimpleString = 0;
        stringState      = JSONStringStateParsing;
        tokenBufferIdx   = (atStringCharacter - stringStart) - 1L;
        if(SGJK_EXPECT_F((tokenBufferIdx + 16UL) > parseState->token.tokenBuffer.bytes.length)) { if((tokenBuffer = SGJK_managedBuffer_resize(&parseState->token.tokenBuffer, tokenBufferIdx + 1024UL)) == NULL) { SGJK_error(parseState, @"Internal error: Unable to resize temporary buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; } }
        memcpy(tokenBuffer, stringStart, tokenBufferIdx);
        goto slowMatch;
      }

      if(SGJK_EXPECT_F(currentChar < 0x20UL)) { SGJK_error(parseState, @"Invalid character < 0x20 found in string: 0x%2.2x.", currentChar); stringState = JSONStringStateError; goto finishedParsing; }

      stringHash = calculateHash(stringHash, currentChar);
    }
  }

 slowMatch:

  for(atStringCharacter = (stringStart + ((atStringCharacter - stringStart) - 1L)); (atStringCharacter < endOfBuffer) && (tokenBufferIdx < parseState->token.tokenBuffer.bytes.length); atStringCharacter++) {
    if((tokenBufferIdx + 16UL) > parseState->token.tokenBuffer.bytes.length) { if((tokenBuffer = SGJK_managedBuffer_resize(&parseState->token.tokenBuffer, tokenBufferIdx + 1024UL)) == NULL) { SGJK_error(parseState, @"Internal error: Unable to resize temporary buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; } }

    NSCParameterAssert(tokenBufferIdx < parseState->token.tokenBuffer.bytes.length);

    unsigned long currentChar = (*atStringCharacter), escapedChar;

    if(SGJK_EXPECT_T(stringState == JSONStringStateParsing)) {
      if(SGJK_EXPECT_T(currentChar >= 0x20UL)) {
        if(SGJK_EXPECT_T(currentChar < (unsigned long)0x80)) { // Not a UTF8 sequence
          if(SGJK_EXPECT_F(currentChar == (unsigned long)'"'))  { stringState = JSONStringStateFinished; atStringCharacter++; goto finishedParsing; }
          if(SGJK_EXPECT_F(currentChar == (unsigned long)'\\')) { stringState = JSONStringStateEscape; continue; }
          stringHash = calculateHash(stringHash, currentChar);
          tokenBuffer[tokenBufferIdx++] = currentChar;
          continue;
        } else { // UTF8 sequence
          const unsigned char *nextValidCharacter = NULL;
          UTF32                u32ch              = 0U;
          ConversionResult     result;
          
          if(SGJK_EXPECT_F((result = ConvertSingleCodePointInUTF8(atStringCharacter, endOfBuffer, (UTF8 const **)&nextValidCharacter, &u32ch)) != conversionOK)) {
            if((result == sourceIllegal) && ((parseState->parseOptionFlags & SGJKParseOptionLooseUnicode) == 0)) { SGJK_error(parseState, @"Illegal UTF8 sequence found in \"\" string.");              stringState = JSONStringStateError; goto finishedParsing; }
            if(result == sourceExhausted)                                                                      { SGJK_error(parseState, @"End of buffer reached while parsing UTF8 in \"\" string."); stringState = JSONStringStateError; goto finishedParsing; }
            if(SGJK_string_add_unicodeCodePoint(parseState, u32ch, &tokenBufferIdx, &stringHash))                { SGJK_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; }
            atStringCharacter = nextValidCharacter - 1;
            continue;
          } else {
            while(atStringCharacter < nextValidCharacter) { tokenBuffer[tokenBufferIdx++] = *atStringCharacter; stringHash = calculateHash(stringHash, *atStringCharacter++); }
            atStringCharacter--;
            continue;
          }
        }
      } else { // currentChar < 0x20
        SGJK_error(parseState, @"Invalid character < 0x20 found in string: 0x%2.2x.", currentChar); stringState = JSONStringStateError; goto finishedParsing;
      }

    } else { // stringState != JSONStringStateParsing
      int isSurrogate = 1;

      switch(stringState) {
        case JSONStringStateEscape:
          switch(currentChar) {
            case 'u': escapedUnicode1 = 0U; escapedUnicode2 = 0U; escapedUnicodeCodePoint = 0U; stringState = JSONStringStateEscapedUnicode1; break;

            case 'b':  escapedChar = '\b'; goto parsedEscapedChar;
            case 'f':  escapedChar = '\f'; goto parsedEscapedChar;
            case 'n':  escapedChar = '\n'; goto parsedEscapedChar;
            case 'r':  escapedChar = '\r'; goto parsedEscapedChar;
            case 't':  escapedChar = '\t'; goto parsedEscapedChar;
            case '\\': escapedChar = '\\'; goto parsedEscapedChar;
            case '/':  escapedChar = '/';  goto parsedEscapedChar;
            case '"':  escapedChar = '"';  goto parsedEscapedChar;
              
            parsedEscapedChar:
              stringState = JSONStringStateParsing;
              stringHash  = calculateHash(stringHash, escapedChar);
              tokenBuffer[tokenBufferIdx++] = escapedChar;
              break;
              
            default: SGJK_error(parseState, @"Invalid escape sequence found in \"\" string."); stringState = JSONStringStateError; goto finishedParsing; break;
          }
          break;

        case JSONStringStateEscapedUnicode1:
        case JSONStringStateEscapedUnicode2:
        case JSONStringStateEscapedUnicode3:
        case JSONStringStateEscapedUnicode4:           isSurrogate = 0;
        case JSONStringStateEscapedUnicodeSurrogate1:
        case JSONStringStateEscapedUnicodeSurrogate2:
        case JSONStringStateEscapedUnicodeSurrogate3:
        case JSONStringStateEscapedUnicodeSurrogate4:
          {
            uint16_t hexValue = 0U;

            switch(currentChar) {
              case '0' ... '9': hexValue =  currentChar - '0';        goto parsedHex;
              case 'a' ... 'f': hexValue = (currentChar - 'a') + 10U; goto parsedHex;
              case 'A' ... 'F': hexValue = (currentChar - 'A') + 10U; goto parsedHex;
                
              parsedHex:
              if(!isSurrogate) { escapedUnicode1 = (escapedUnicode1 << 4) | hexValue; } else { escapedUnicode2 = (escapedUnicode2 << 4) | hexValue; }
                
              if(stringState == JSONStringStateEscapedUnicode4) {
                if(((escapedUnicode1 >= 0xD800U) && (escapedUnicode1 < 0xE000U))) {
                  if((escapedUnicode1 >= 0xD800U) && (escapedUnicode1 < 0xDC00U)) { stringState = JSONStringStateEscapedNeedEscapeForSurrogate; }
                  else if((escapedUnicode1 >= 0xDC00U) && (escapedUnicode1 < 0xE000U)) { 
                    if((parseState->parseOptionFlags & SGJKParseOptionLooseUnicode)) { escapedUnicodeCodePoint = UNI_REPLACEMENT_CHAR; }
                    else { SGJK_error(parseState, @"Illegal \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
                  }
                }
                else { escapedUnicodeCodePoint = escapedUnicode1; }
              }

              if(stringState == JSONStringStateEscapedUnicodeSurrogate4) {
                if((escapedUnicode2 < 0xdc00) || (escapedUnicode2 > 0xdfff)) {
                  if((parseState->parseOptionFlags & SGJKParseOptionLooseUnicode)) { escapedUnicodeCodePoint = UNI_REPLACEMENT_CHAR; }
                  else { SGJK_error(parseState, @"Illegal \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
                }
                else { escapedUnicodeCodePoint = ((escapedUnicode1 - 0xd800) * 0x400) + (escapedUnicode2 - 0xdc00) + 0x10000; }
              }
                
              if((stringState == JSONStringStateEscapedUnicode4) || (stringState == JSONStringStateEscapedUnicodeSurrogate4)) { 
                if((isValidCodePoint(&escapedUnicodeCodePoint) == sourceIllegal) && ((parseState->parseOptionFlags & SGJKParseOptionLooseUnicode) == 0)) { SGJK_error(parseState, @"Illegal \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
                stringState = JSONStringStateParsing;
                if(SGJK_string_add_unicodeCodePoint(parseState, escapedUnicodeCodePoint, &tokenBufferIdx, &stringHash)) { SGJK_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; }
              }
              else if((stringState >= JSONStringStateEscapedUnicode1) && (stringState <= JSONStringStateEscapedUnicodeSurrogate4)) { stringState++; }
              break;

              default: SGJK_error(parseState, @"Unexpected character found in \\u Unicode escape sequence.  Found '%c', expected [0-9a-fA-F].", currentChar); stringState = JSONStringStateError; goto finishedParsing; break;
            }
          }
          break;

        case JSONStringStateEscapedNeedEscapeForSurrogate:
          if(currentChar == '\\') { stringState = JSONStringStateEscapedNeedEscapedUForSurrogate; }
          else { 
            if((parseState->parseOptionFlags & SGJKParseOptionLooseUnicode) == 0) { SGJK_error(parseState, @"Required a second \\u Unicode escape sequence following a surrogate \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
            else { stringState = JSONStringStateParsing; atStringCharacter--;    if(SGJK_string_add_unicodeCodePoint(parseState, UNI_REPLACEMENT_CHAR, &tokenBufferIdx, &stringHash)) { SGJK_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; } }
          }
          break;

        case JSONStringStateEscapedNeedEscapedUForSurrogate:
          if(currentChar == 'u') { stringState = JSONStringStateEscapedUnicodeSurrogate1; }
          else { 
            if((parseState->parseOptionFlags & SGJKParseOptionLooseUnicode) == 0) { SGJK_error(parseState, @"Required a second \\u Unicode escape sequence following a surrogate \\u Unicode escape sequence."); stringState = JSONStringStateError; goto finishedParsing; }
            else { stringState = JSONStringStateParsing; atStringCharacter -= 2; if(SGJK_string_add_unicodeCodePoint(parseState, UNI_REPLACEMENT_CHAR, &tokenBufferIdx, &stringHash)) { SGJK_error(parseState, @"Internal error: Unable to add UTF8 sequence to internal string buffer. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; } }
          }
          break;

        default: SGJK_error(parseState, @"Internal error: Unknown stringState. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); stringState = JSONStringStateError; goto finishedParsing; break;
      }
    }
  }

finishedParsing:

  if(SGJK_EXPECT_T(stringState == JSONStringStateFinished)) {
    NSCParameterAssert((parseState->stringBuffer.bytes.ptr + tokenStartIndex) < atStringCharacter);

    parseState->token.tokenPtrRange.ptr    = parseState->stringBuffer.bytes.ptr + tokenStartIndex;
    parseState->token.tokenPtrRange.length = (atStringCharacter - parseState->token.tokenPtrRange.ptr);

    if(SGJK_EXPECT_T(onlySimpleString)) {
      NSCParameterAssert(((parseState->token.tokenPtrRange.ptr + 1) < endOfBuffer) && (parseState->token.tokenPtrRange.length >= 2UL) && (((parseState->token.tokenPtrRange.ptr + 1) + (parseState->token.tokenPtrRange.length - 2)) < endOfBuffer));
      parseState->token.value.ptrRange.ptr    = parseState->token.tokenPtrRange.ptr    + 1;
      parseState->token.value.ptrRange.length = parseState->token.tokenPtrRange.length - 2UL;
    } else {
      parseState->token.value.ptrRange.ptr    = parseState->token.tokenBuffer.bytes.ptr;
      parseState->token.value.ptrRange.length = tokenBufferIdx;
    }
    
    parseState->token.value.hash = stringHash;
    parseState->token.value.type = SGJKValueTypeString;
    parseState->atIndex          = (atStringCharacter - parseState->stringBuffer.bytes.ptr);
  }

  if(SGJK_EXPECT_F(stringState != JSONStringStateFinished)) { SGJK_error(parseState, @"Invalid string."); }
  return(SGJK_EXPECT_T(stringState == JSONStringStateFinished) ? 0 : 1);
}

static int SGJK_parse_number(SGJKParseState *parseState) {
  NSCParameterAssert((parseState != NULL) && (SGJK_AT_STRING_PTR(parseState) <= SGJK_END_STRING_PTR(parseState)));
  const unsigned char *numberStart       = SGJK_AT_STRING_PTR(parseState);
  const unsigned char *endOfBuffer       = SGJK_END_STRING_PTR(parseState);
  const unsigned char *atNumberCharacter = NULL;
  int                  numberState       = JSONNumberStateWholeNumberStart, isFloatingPoint = 0, isNegative = 0, backup = 0;
  size_t               startingIndex     = parseState->atIndex;
  
  for(atNumberCharacter = numberStart; (SGJK_EXPECT_T(atNumberCharacter < endOfBuffer)) && (SGJK_EXPECT_T(!(SGJK_EXPECT_F(numberState == JSONNumberStateFinished) || SGJK_EXPECT_F(numberState == JSONNumberStateError)))); atNumberCharacter++) {
    unsigned long currentChar = (unsigned long)(*atNumberCharacter), lowerCaseCC = currentChar | 0x20UL;
    
    switch(numberState) {
      case JSONNumberStateWholeNumberStart: if   (currentChar == '-')                                                                              { numberState = JSONNumberStateWholeNumberMinus;      isNegative      = 1; break; }
      case JSONNumberStateWholeNumberMinus: if   (currentChar == '0')                                                                              { numberState = JSONNumberStateWholeNumberZero;                            break; }
                                       else if(  (currentChar >= '1') && (currentChar <= '9'))                                                     { numberState = JSONNumberStateWholeNumber;                                break; }
                                       else                                                     { /* XXX Add error message */                        numberState = JSONNumberStateError;                                      break; }
      case JSONNumberStateExponentStart:    if(  (currentChar == '+') || (currentChar == '-'))                                                     { numberState = JSONNumberStateExponentPlusMinus;                          break; }
      case JSONNumberStateFractionalNumberStart:
      case JSONNumberStateExponentPlusMinus:if(!((currentChar >= '0') && (currentChar <= '9'))) { /* XXX Add error message */                        numberState = JSONNumberStateError;                                      break; }
                                       else {                                              if(numberState == JSONNumberStateFractionalNumberStart) { numberState = JSONNumberStateFractionalNumber; }
                                                                                           else                                                    { numberState = JSONNumberStateExponent;         }                         break; }
      case JSONNumberStateWholeNumberZero:
      case JSONNumberStateWholeNumber:      if   (currentChar == '.')                                                                              { numberState = JSONNumberStateFractionalNumberStart; isFloatingPoint = 1; break; }
      case JSONNumberStateFractionalNumber: if   (lowerCaseCC == 'e')                                                                              { numberState = JSONNumberStateExponentStart;         isFloatingPoint = 1; break; }
      case JSONNumberStateExponent:         if(!((currentChar >= '0') && (currentChar <= '9')) || (numberState == JSONNumberStateWholeNumberZero)) { numberState = JSONNumberStateFinished;              backup          = 1; break; }
        break;
      default:                                                                                    /* XXX Add error message */                        numberState = JSONNumberStateError;                                      break;
    }
  }
  
  parseState->token.tokenPtrRange.ptr    = parseState->stringBuffer.bytes.ptr + startingIndex;
  parseState->token.tokenPtrRange.length = (atNumberCharacter - parseState->token.tokenPtrRange.ptr) - backup;
  parseState->atIndex                    = (parseState->token.tokenPtrRange.ptr + parseState->token.tokenPtrRange.length) - parseState->stringBuffer.bytes.ptr;

  if(SGJK_EXPECT_T(numberState == JSONNumberStateFinished)) {
    unsigned char  numberTempBuf[parseState->token.tokenPtrRange.length + 4UL];
    unsigned char *endOfNumber = NULL;

    memcpy(numberTempBuf, parseState->token.tokenPtrRange.ptr, parseState->token.tokenPtrRange.length);
    numberTempBuf[parseState->token.tokenPtrRange.length] = 0;

    errno = 0;
    
    // Treat "-0" as a floating point number, which is capable of representing negative zeros.
    if(SGJK_EXPECT_F(parseState->token.tokenPtrRange.length == 2UL) && SGJK_EXPECT_F(numberTempBuf[1] == '0') && SGJK_EXPECT_F(isNegative)) { isFloatingPoint = 1; }

    if(isFloatingPoint) {
      parseState->token.value.number.doubleValue = strtod((const char *)numberTempBuf, (char **)&endOfNumber); // strtod is documented to return U+2261 (identical to) 0.0 on an underflow error (along with setting errno to ERANGE).
      parseState->token.value.type               = SGJKValueTypeDouble;
      parseState->token.value.ptrRange.ptr       = (const unsigned char *)&parseState->token.value.number.doubleValue;
      parseState->token.value.ptrRange.length    = sizeof(double);
      parseState->token.value.hash               = (SGJK_HASH_INIT + parseState->token.value.type);
    } else {
      if(isNegative) {
        parseState->token.value.number.longLongValue = strtoll((const char *)numberTempBuf, (char **)&endOfNumber, 10);
        parseState->token.value.type                 = SGJKValueTypeLongLong;
        parseState->token.value.ptrRange.ptr         = (const unsigned char *)&parseState->token.value.number.longLongValue;
        parseState->token.value.ptrRange.length      = sizeof(long long);
        parseState->token.value.hash                 = (SGJK_HASH_INIT + parseState->token.value.type) + (SGJKHash)parseState->token.value.number.longLongValue;
      } else {
        parseState->token.value.number.unsignedLongLongValue = strtoull((const char *)numberTempBuf, (char **)&endOfNumber, 10);
        parseState->token.value.type                         = SGJKValueTypeUnsignedLongLong;
        parseState->token.value.ptrRange.ptr                 = (const unsigned char *)&parseState->token.value.number.unsignedLongLongValue;
        parseState->token.value.ptrRange.length              = sizeof(unsigned long long);
        parseState->token.value.hash                         = (SGJK_HASH_INIT + parseState->token.value.type) + (SGJKHash)parseState->token.value.number.unsignedLongLongValue;
      }
    }

    if(SGJK_EXPECT_F(errno != 0)) {
      numberState = JSONNumberStateError;
      if(errno == ERANGE) {
        switch(parseState->token.value.type) {
          case SGJKValueTypeDouble:           SGJK_error(parseState, @"The value '%s' could not be represented as a 'double' due to %s.",           numberTempBuf, (parseState->token.value.number.doubleValue == 0.0) ? "underflow" : "overflow"); break; // see above for == 0.0.
          case SGJKValueTypeLongLong:         SGJK_error(parseState, @"The value '%s' exceeded the minimum value that could be represented: %lld.", numberTempBuf, parseState->token.value.number.longLongValue);                                   break;
          case SGJKValueTypeUnsignedLongLong: SGJK_error(parseState, @"The value '%s' exceeded the maximum value that could be represented: %llu.", numberTempBuf, parseState->token.value.number.unsignedLongLongValue);                           break;
          default:                          SGJK_error(parseState, @"Internal error: Unknown token value type. %@ line #%ld",                     [NSString stringWithUTF8String:__FILE__], (long)__LINE__);                                      break;
        }
      }
    }
    if(SGJK_EXPECT_F(endOfNumber != &numberTempBuf[parseState->token.tokenPtrRange.length]) && SGJK_EXPECT_F(numberState != JSONNumberStateError)) { numberState = JSONNumberStateError; SGJK_error(parseState, @"The conversion function did not consume all of the number tokens characters."); }

    size_t hashIndex = 0UL;
    for(hashIndex = 0UL; hashIndex < parseState->token.value.ptrRange.length; hashIndex++) { parseState->token.value.hash = calculateHash(parseState->token.value.hash, parseState->token.value.ptrRange.ptr[hashIndex]); }
  }

  if(SGJK_EXPECT_F(numberState != JSONNumberStateFinished)) { SGJK_error(parseState, @"Invalid number."); }
  return(SGJK_EXPECT_T((numberState == JSONNumberStateFinished)) ? 0 : 1);
}

SGJK_STATIC_INLINE void SGJK_set_parsed_token(SGJKParseState *parseState, const unsigned char *ptr, size_t length, SGJKTokenType type, size_t advanceBy) {
  parseState->token.tokenPtrRange.ptr     = ptr;
  parseState->token.tokenPtrRange.length  = length;
  parseState->token.type                  = type;
  parseState->atIndex                    += advanceBy;
}

static size_t SGJK_parse_is_newline(SGJKParseState *parseState, const unsigned char *atCharacterPtr) {
  NSCParameterAssert((parseState != NULL) && (atCharacterPtr != NULL) && (atCharacterPtr >= parseState->stringBuffer.bytes.ptr) && (atCharacterPtr < SGJK_END_STRING_PTR(parseState)));
  const unsigned char *endOfStringPtr = SGJK_END_STRING_PTR(parseState);

  if(SGJK_EXPECT_F(atCharacterPtr >= endOfStringPtr)) { return(0UL); }

  if(SGJK_EXPECT_F((*(atCharacterPtr + 0)) == '\n')) { return(1UL); }
  if(SGJK_EXPECT_F((*(atCharacterPtr + 0)) == '\r')) { if((SGJK_EXPECT_T((atCharacterPtr + 1) < endOfStringPtr)) && ((*(atCharacterPtr + 1)) == '\n')) { return(2UL); } return(1UL); }
  if(parseState->parseOptionFlags & SGJKParseOptionUnicodeNewlines) {
    if((SGJK_EXPECT_F((*(atCharacterPtr + 0)) == 0xc2)) && (((atCharacterPtr + 1) < endOfStringPtr) && ((*(atCharacterPtr + 1)) == 0x85))) { return(2UL); }
    if((SGJK_EXPECT_F((*(atCharacterPtr + 0)) == 0xe2)) && (((atCharacterPtr + 2) < endOfStringPtr) && ((*(atCharacterPtr + 1)) == 0x80) && (((*(atCharacterPtr + 2)) == 0xa8) || ((*(atCharacterPtr + 2)) == 0xa9)))) { return(3UL); }
  }

  return(0UL);
}

SGJK_STATIC_INLINE int SGJK_parse_skip_newline(SGJKParseState *parseState) {
  size_t newlineAdvanceAtIndex = 0UL;
  if(SGJK_EXPECT_F((newlineAdvanceAtIndex = SGJK_parse_is_newline(parseState, SGJK_AT_STRING_PTR(parseState))) > 0UL)) { parseState->lineNumber++; parseState->atIndex += (newlineAdvanceAtIndex - 1UL); parseState->lineStartIndex = parseState->atIndex + 1UL; return(1); }
  return(0);
}

SGJK_STATIC_INLINE void SGJK_parse_skip_whitespace(SGJKParseState *parseState) {
#ifndef __clang_analyzer__
  NSCParameterAssert((parseState != NULL) && (SGJK_AT_STRING_PTR(parseState) <= SGJK_END_STRING_PTR(parseState)));
  const unsigned char *atCharacterPtr   = NULL;
  const unsigned char *endOfStringPtr   = SGJK_END_STRING_PTR(parseState);

  for(atCharacterPtr = SGJK_AT_STRING_PTR(parseState); (SGJK_EXPECT_T((atCharacterPtr = SGJK_AT_STRING_PTR(parseState)) < endOfStringPtr)); parseState->atIndex++) {
    if(((*(atCharacterPtr + 0)) == ' ') || ((*(atCharacterPtr + 0)) == '\t')) { continue; }
    if(SGJK_parse_skip_newline(parseState)) { continue; }
    if(parseState->parseOptionFlags & SGJKParseOptionComments) {
      if((SGJK_EXPECT_F((*(atCharacterPtr + 0)) == '/')) && (SGJK_EXPECT_T((atCharacterPtr + 1) < endOfStringPtr))) {
        if((*(atCharacterPtr + 1)) == '/') {
          parseState->atIndex++;
          for(atCharacterPtr = SGJK_AT_STRING_PTR(parseState); (SGJK_EXPECT_T((atCharacterPtr = SGJK_AT_STRING_PTR(parseState)) < endOfStringPtr)); parseState->atIndex++) { if(SGJK_parse_skip_newline(parseState)) { break; } }
          continue;
        }
        if((*(atCharacterPtr + 1)) == '*') {
          parseState->atIndex++;
          for(atCharacterPtr = SGJK_AT_STRING_PTR(parseState); (SGJK_EXPECT_T((atCharacterPtr = SGJK_AT_STRING_PTR(parseState)) < endOfStringPtr)); parseState->atIndex++) {
            if(SGJK_parse_skip_newline(parseState)) { continue; }
            if(((*(atCharacterPtr + 0)) == '*') && (((atCharacterPtr + 1) < endOfStringPtr) && ((*(atCharacterPtr + 1)) == '/'))) { parseState->atIndex++; break; }
          }
          continue;
        }
      }
    }
    break;
  }
#endif
}

static int SGJK_parse_next_token(SGJKParseState *parseState) {
  NSCParameterAssert((parseState != NULL) && (SGJK_AT_STRING_PTR(parseState) <= SGJK_END_STRING_PTR(parseState)));
  const unsigned char *atCharacterPtr   = NULL;
  const unsigned char *endOfStringPtr   = SGJK_END_STRING_PTR(parseState);
  unsigned char        currentCharacter = 0U;
  int                  stopParsing      = 0;

  parseState->prev_atIndex        = parseState->atIndex;
  parseState->prev_lineNumber     = parseState->lineNumber;
  parseState->prev_lineStartIndex = parseState->lineStartIndex;

  SGJK_parse_skip_whitespace(parseState);

  if((SGJK_AT_STRING_PTR(parseState) == endOfStringPtr)) { stopParsing = 1; }

  if((SGJK_EXPECT_T(stopParsing == 0)) && (SGJK_EXPECT_T((atCharacterPtr = SGJK_AT_STRING_PTR(parseState)) < endOfStringPtr))) {
    currentCharacter = *atCharacterPtr;

         if(SGJK_EXPECT_T(currentCharacter == '"')) { if(SGJK_EXPECT_T((stopParsing = SGJK_parse_string(parseState)) == 0)) { SGJK_set_parsed_token(parseState, parseState->token.tokenPtrRange.ptr, parseState->token.tokenPtrRange.length, SGJKTokenTypeString, 0UL); } }
    else if(SGJK_EXPECT_T(currentCharacter == ':')) { SGJK_set_parsed_token(parseState, atCharacterPtr, 1UL, SGJKTokenTypeSeparator,   1UL); }
    else if(SGJK_EXPECT_T(currentCharacter == ',')) { SGJK_set_parsed_token(parseState, atCharacterPtr, 1UL, SGJKTokenTypeComma,       1UL); }
    else if((SGJK_EXPECT_T(currentCharacter >= '0') && SGJK_EXPECT_T(currentCharacter <= '9')) || SGJK_EXPECT_T(currentCharacter == '-')) { if(SGJK_EXPECT_T((stopParsing = SGJK_parse_number(parseState)) == 0)) { SGJK_set_parsed_token(parseState, parseState->token.tokenPtrRange.ptr, parseState->token.tokenPtrRange.length, SGJKTokenTypeNumber, 0UL); } }
    else if(SGJK_EXPECT_T(currentCharacter == '{')) { SGJK_set_parsed_token(parseState, atCharacterPtr, 1UL, SGJKTokenTypeObjectBegin, 1UL); }
    else if(SGJK_EXPECT_T(currentCharacter == '}')) { SGJK_set_parsed_token(parseState, atCharacterPtr, 1UL, SGJKTokenTypeObjectEnd,   1UL); }
    else if(SGJK_EXPECT_T(currentCharacter == '[')) { SGJK_set_parsed_token(parseState, atCharacterPtr, 1UL, SGJKTokenTypeArrayBegin,  1UL); }
    else if(SGJK_EXPECT_T(currentCharacter == ']')) { SGJK_set_parsed_token(parseState, atCharacterPtr, 1UL, SGJKTokenTypeArrayEnd,    1UL); }
    
    else if(SGJK_EXPECT_T(currentCharacter == 't')) { if(!((SGJK_EXPECT_T((atCharacterPtr + 4UL) < endOfStringPtr)) && (SGJK_EXPECT_T(atCharacterPtr[1] == 'r')) && (SGJK_EXPECT_T(atCharacterPtr[2] == 'u')) && (SGJK_EXPECT_T(atCharacterPtr[3] == 'e'))))                                            { stopParsing = 1; /* XXX Add error message */ } else { SGJK_set_parsed_token(parseState, atCharacterPtr, 4UL, SGJKTokenTypeTrue,  4UL); } }
    else if(SGJK_EXPECT_T(currentCharacter == 'f')) { if(!((SGJK_EXPECT_T((atCharacterPtr + 5UL) < endOfStringPtr)) && (SGJK_EXPECT_T(atCharacterPtr[1] == 'a')) && (SGJK_EXPECT_T(atCharacterPtr[2] == 'l')) && (SGJK_EXPECT_T(atCharacterPtr[3] == 's')) && (SGJK_EXPECT_T(atCharacterPtr[4] == 'e')))) { stopParsing = 1; /* XXX Add error message */ } else { SGJK_set_parsed_token(parseState, atCharacterPtr, 5UL, SGJKTokenTypeFalse, 5UL); } }
    else if(SGJK_EXPECT_T(currentCharacter == 'n')) { if(!((SGJK_EXPECT_T((atCharacterPtr + 4UL) < endOfStringPtr)) && (SGJK_EXPECT_T(atCharacterPtr[1] == 'u')) && (SGJK_EXPECT_T(atCharacterPtr[2] == 'l')) && (SGJK_EXPECT_T(atCharacterPtr[3] == 'l'))))                                            { stopParsing = 1; /* XXX Add error message */ } else { SGJK_set_parsed_token(parseState, atCharacterPtr, 4UL, SGJKTokenTypeNull,  4UL); } }
    else { stopParsing = 1; /* XXX Add error message */ }    
  }

  if(SGJK_EXPECT_F(stopParsing)) { SGJK_error(parseState, @"Unexpected token, wanted '{', '}', '[', ']', ',', ':', 'true', 'false', 'null', '\"STRING\"', 'NUMBER'."); }
  return(stopParsing);
}

static void SGJK_error_parse_accept_or3(SGJKParseState *parseState, int state, NSString *or1String, NSString *or2String, NSString *or3String) {
  NSString *acceptStrings[16];
  int acceptIdx = 0;
  if(state & SGJKParseAcceptValue) { acceptStrings[acceptIdx++] = or1String; }
  if(state & SGJKParseAcceptComma) { acceptStrings[acceptIdx++] = or2String; }
  if(state & SGJKParseAcceptEnd)   { acceptStrings[acceptIdx++] = or3String; }
       if(acceptIdx == 1) { SGJK_error(parseState, @"Expected %@, not '%*.*s'",           acceptStrings[0],                                     (int)parseState->token.tokenPtrRange.length, (int)parseState->token.tokenPtrRange.length, parseState->token.tokenPtrRange.ptr); }
  else if(acceptIdx == 2) { SGJK_error(parseState, @"Expected %@ or %@, not '%*.*s'",     acceptStrings[0], acceptStrings[1],                   (int)parseState->token.tokenPtrRange.length, (int)parseState->token.tokenPtrRange.length, parseState->token.tokenPtrRange.ptr); }
  else if(acceptIdx == 3) { SGJK_error(parseState, @"Expected %@, %@, or %@, not '%*.*s", acceptStrings[0], acceptStrings[1], acceptStrings[2], (int)parseState->token.tokenPtrRange.length, (int)parseState->token.tokenPtrRange.length, parseState->token.tokenPtrRange.ptr); }
}

static void *SGJK_parse_array(SGJKParseState *parseState) {
  size_t  startingObjectIndex = parseState->objectStack.index;
  int     arrayState          = SGJKParseAcceptValueOrEnd, stopParsing = 0;
  void   *parsedArray         = NULL;

  while(SGJK_EXPECT_T((SGJK_EXPECT_T(stopParsing == 0)) && (SGJK_EXPECT_T(parseState->atIndex < parseState->stringBuffer.bytes.length)))) {
    if(SGJK_EXPECT_F(parseState->objectStack.index > (parseState->objectStack.count - 4UL))) { if(SGJK_objectStack_resize(&parseState->objectStack, parseState->objectStack.count + 128UL)) { SGJK_error(parseState, @"Internal error: [array] objectsIndex > %zu, resize failed? %@ line %#ld", (parseState->objectStack.count - 4UL), [NSString stringWithUTF8String:__FILE__], (long)__LINE__); break; } }

    if(SGJK_EXPECT_T((stopParsing = SGJK_parse_next_token(parseState)) == 0)) {
      void *object = NULL;
#ifndef NS_BLOCK_ASSERTIONS
      parseState->objectStack.objects[parseState->objectStack.index] = NULL;
      parseState->objectStack.keys   [parseState->objectStack.index] = NULL;
#endif
      switch(parseState->token.type) {
        case SGJKTokenTypeNumber:
        case SGJKTokenTypeString:
        case SGJKTokenTypeTrue:
        case SGJKTokenTypeFalse:
        case SGJKTokenTypeNull:
        case SGJKTokenTypeArrayBegin:
        case SGJKTokenTypeObjectBegin:
          if(SGJK_EXPECT_F((arrayState & SGJKParseAcceptValue)          == 0))    { parseState->errorIsPrev = 1; SGJK_error(parseState, @"Unexpected value.");              stopParsing = 1; break; }
          if(SGJK_EXPECT_F((object = SGJK_object_for_token(parseState)) == NULL)) {                              SGJK_error(parseState, @"Internal error: Object == NULL"); stopParsing = 1; break; } else { parseState->objectStack.objects[parseState->objectStack.index++] = object; arrayState = SGJKParseAcceptCommaOrEnd; }
          break;
        case SGJKTokenTypeArrayEnd: if(SGJK_EXPECT_T(arrayState & SGJKParseAcceptEnd)) { NSCParameterAssert(parseState->objectStack.index >= startingObjectIndex); parsedArray = (void *)_SGJKArrayCreate((id *)&parseState->objectStack.objects[startingObjectIndex], (parseState->objectStack.index - startingObjectIndex), parseState->mutableCollections); } else { parseState->errorIsPrev = 1; SGJK_error(parseState, @"Unexpected ']'."); } stopParsing = 1; break;
        case SGJKTokenTypeComma:    if(SGJK_EXPECT_T(arrayState & SGJKParseAcceptComma)) { arrayState = SGJKParseAcceptValue; } else { parseState->errorIsPrev = 1; SGJK_error(parseState, @"Unexpected ','."); stopParsing = 1; } break;
        default: parseState->errorIsPrev = 1; SGJK_error_parse_accept_or3(parseState, arrayState, @"a value", @"a comma", @"a ']'"); stopParsing = 1; break;
      }
    }
  }

  if(SGJK_EXPECT_F(parsedArray == NULL)) { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { if(parseState->objectStack.objects[idx] != NULL) { CFRelease(parseState->objectStack.objects[idx]); parseState->objectStack.objects[idx] = NULL; } } }
#if !defined(NS_BLOCK_ASSERTIONS)
  else { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { parseState->objectStack.objects[idx] = NULL; parseState->objectStack.keys[idx] = NULL; } }
#endif
  
  parseState->objectStack.index = startingObjectIndex;
  return(parsedArray);
}

static void *SGJK_create_dictionary(SGJKParseState *parseState, size_t startingObjectIndex) {
  void *parsedDictionary = NULL;

  parseState->objectStack.index--;

  parsedDictionary = _SGJKDictionaryCreate((id *)&parseState->objectStack.keys[startingObjectIndex], (NSUInteger *)&parseState->objectStack.cfHashes[startingObjectIndex], (id *)&parseState->objectStack.objects[startingObjectIndex], (parseState->objectStack.index - startingObjectIndex), parseState->mutableCollections);

  return(parsedDictionary);
}

static void *SGJK_parse_dictionary(SGJKParseState *parseState) {
  size_t  startingObjectIndex = parseState->objectStack.index;
  int     dictState           = SGJKParseAcceptValueOrEnd, stopParsing = 0;
  void   *parsedDictionary    = NULL;

  while(SGJK_EXPECT_T((SGJK_EXPECT_T(stopParsing == 0)) && (SGJK_EXPECT_T(parseState->atIndex < parseState->stringBuffer.bytes.length)))) {
    if(SGJK_EXPECT_F(parseState->objectStack.index > (parseState->objectStack.count - 4UL))) { if(SGJK_objectStack_resize(&parseState->objectStack, parseState->objectStack.count + 128UL)) { SGJK_error(parseState, @"Internal error: [dictionary] objectsIndex > %zu, resize failed? %@ line #%ld", (parseState->objectStack.count - 4UL), [NSString stringWithUTF8String:__FILE__], (long)__LINE__); break; } }

    size_t objectStackIndex = parseState->objectStack.index++;
    parseState->objectStack.keys[objectStackIndex]    = NULL;
    parseState->objectStack.objects[objectStackIndex] = NULL;
    void *key = NULL, *object = NULL;

    if(SGJK_EXPECT_T((SGJK_EXPECT_T(stopParsing == 0)) && (SGJK_EXPECT_T((stopParsing = SGJK_parse_next_token(parseState)) == 0)))) {
      switch(parseState->token.type) {
        case SGJKTokenTypeString:
          if(SGJK_EXPECT_F((dictState & SGJKParseAcceptValue)        == 0))    { parseState->errorIsPrev = 1; SGJK_error(parseState, @"Unexpected string.");           stopParsing = 1; break; }
          if(SGJK_EXPECT_F((key = SGJK_object_for_token(parseState)) == NULL)) {                              SGJK_error(parseState, @"Internal error: Key == NULL."); stopParsing = 1; break; }
          else {
            parseState->objectStack.keys[objectStackIndex] = key;
            if(SGJK_EXPECT_T(parseState->token.value.cacheItem != NULL)) { if(SGJK_EXPECT_F(parseState->token.value.cacheItem->cfHash == 0UL)) { parseState->token.value.cacheItem->cfHash = CFHash(key); } parseState->objectStack.cfHashes[objectStackIndex] = parseState->token.value.cacheItem->cfHash; }
            else { parseState->objectStack.cfHashes[objectStackIndex] = CFHash(key); }
          }
          break;

        case SGJKTokenTypeObjectEnd: if((SGJK_EXPECT_T(dictState & SGJKParseAcceptEnd)))   { NSCParameterAssert(parseState->objectStack.index >= startingObjectIndex); parsedDictionary = SGJK_create_dictionary(parseState, startingObjectIndex); } else { parseState->errorIsPrev = 1; SGJK_error(parseState, @"Unexpected '}'."); } stopParsing = 1; break;
        case SGJKTokenTypeComma:     if((SGJK_EXPECT_T(dictState & SGJKParseAcceptComma))) { dictState = SGJKParseAcceptValue; parseState->objectStack.index--; continue; } else { parseState->errorIsPrev = 1; SGJK_error(parseState, @"Unexpected ','."); stopParsing = 1; } break;

        default: parseState->errorIsPrev = 1; SGJK_error_parse_accept_or3(parseState, dictState, @"a \"STRING\"", @"a comma", @"a '}'"); stopParsing = 1; break;
      }
    }

    if(SGJK_EXPECT_T(stopParsing == 0)) {
      if(SGJK_EXPECT_T((stopParsing = SGJK_parse_next_token(parseState)) == 0)) { if(SGJK_EXPECT_F(parseState->token.type != SGJKTokenTypeSeparator)) { parseState->errorIsPrev = 1; SGJK_error(parseState, @"Expected ':'."); stopParsing = 1; } }
    }

    if((SGJK_EXPECT_T(stopParsing == 0)) && (SGJK_EXPECT_T((stopParsing = SGJK_parse_next_token(parseState)) == 0))) {
      switch(parseState->token.type) {
        case SGJKTokenTypeNumber:
        case SGJKTokenTypeString:
        case SGJKTokenTypeTrue:
        case SGJKTokenTypeFalse:
        case SGJKTokenTypeNull:
        case SGJKTokenTypeArrayBegin:
        case SGJKTokenTypeObjectBegin:
          if(SGJK_EXPECT_F((dictState & SGJKParseAcceptValue)           == 0))    { parseState->errorIsPrev = 1; SGJK_error(parseState, @"Unexpected value.");               stopParsing = 1; break; }
          if(SGJK_EXPECT_F((object = SGJK_object_for_token(parseState)) == NULL)) {                              SGJK_error(parseState, @"Internal error: Object == NULL."); stopParsing = 1; break; } else { parseState->objectStack.objects[objectStackIndex] = object; dictState = SGJKParseAcceptCommaOrEnd; }
          break;
        default: parseState->errorIsPrev = 1; SGJK_error_parse_accept_or3(parseState, dictState, @"a value", @"a comma", @"a '}'"); stopParsing = 1; break;
      }
    }
  }

  if(SGJK_EXPECT_F(parsedDictionary == NULL)) { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { if(parseState->objectStack.keys[idx] != NULL) { CFRelease(parseState->objectStack.keys[idx]); parseState->objectStack.keys[idx] = NULL; } if(parseState->objectStack.objects[idx] != NULL) { CFRelease(parseState->objectStack.objects[idx]); parseState->objectStack.objects[idx] = NULL; } } }
#if !defined(NS_BLOCK_ASSERTIONS)
  else { size_t idx = 0UL; for(idx = startingObjectIndex; idx < parseState->objectStack.index; idx++) { parseState->objectStack.objects[idx] = NULL; parseState->objectStack.keys[idx] = NULL; } }
#endif

  parseState->objectStack.index = startingObjectIndex;
  return(parsedDictionary);
}

static id json_parse_it(SGJKParseState *parseState) {
  id  parsedObject = NULL;
  int stopParsing  = 0;

  while((SGJK_EXPECT_T(stopParsing == 0)) && (SGJK_EXPECT_T(parseState->atIndex < parseState->stringBuffer.bytes.length))) {
    if((SGJK_EXPECT_T(stopParsing == 0)) && (SGJK_EXPECT_T((stopParsing = SGJK_parse_next_token(parseState)) == 0))) {
      switch(parseState->token.type) {
        case SGJKTokenTypeArrayBegin:
        case SGJKTokenTypeObjectBegin: parsedObject = [(id)SGJK_object_for_token(parseState) autorelease]; stopParsing = 1; break;
        default:                     SGJK_error(parseState, @"Expected either '[' or '{'.");             stopParsing = 1; break;
      }
    }
  }

  NSCParameterAssert((parseState->objectStack.index == 0) && (SGJK_AT_STRING_PTR(parseState) <= SGJK_END_STRING_PTR(parseState)));

  if((parsedObject == NULL) && (SGJK_AT_STRING_PTR(parseState) == SGJK_END_STRING_PTR(parseState))) { SGJK_error(parseState, @"Reached the end of the buffer."); }
  if(parsedObject == NULL) { SGJK_error(parseState, @"Unable to parse JSON."); }

  if((parsedObject != NULL) && (SGJK_AT_STRING_PTR(parseState) < SGJK_END_STRING_PTR(parseState))) {
    SGJK_parse_skip_whitespace(parseState);
    if((parsedObject != NULL) && ((parseState->parseOptionFlags & SGJKParseOptionPermitTextAfterValidJSON) == 0) && (SGJK_AT_STRING_PTR(parseState) < SGJK_END_STRING_PTR(parseState))) {
      SGJK_error(parseState, @"A valid JSON object was parsed but there were additional non-white-space characters remaining.");
      parsedObject = NULL;
    }
  }

  return(parsedObject);
}

////////////
#pragma mark -
#pragma mark Object cache

// This uses a Galois Linear Feedback Shift Register (LFSR) PRNG to pick which item in the cache to age. It has a period of (2^32)-1.
// NOTE: A LFSR *MUST* be initialized to a non-zero value and must always have a non-zero value.
SGJK_STATIC_INLINE void SGJK_cache_age(SGJKParseState *parseState) {
  NSCParameterAssert((parseState != NULL) && (parseState->cache.prng_lfsr != 0U));
  parseState->cache.prng_lfsr = (parseState->cache.prng_lfsr >> 1) ^ ((0U - (parseState->cache.prng_lfsr & 1U)) & 0x80200003U);
  parseState->cache.age[parseState->cache.prng_lfsr & (parseState->cache.count - 1UL)] >>= 1;
}

// The object cache is nothing more than a hash table with open addressing collision resolution that is bounded by SGJK_CACHE_PROBES attempts.
//
// The hash table is a linear C array of SGJKTokenCacheItem.  The terms "item" and "bucket" are synonymous with the index in to the cache array, i.e. cache.items[bucket].
//
// Items in the cache have an age associated with them.  The age is the number of rightmost 1 bits, i.e. 0000 = 0, 0001 = 1, 0011 = 2, 0111 = 3, 1111 = 4.
// This allows us to use left and right shifts to add or subtract from an items age.  Add = (age << 1) | 1.  Subtract = age >> 0.  Subtract is synonymous with "age" (i.e., age an item).
// The reason for this is it allows us to perform saturated adds and subtractions and is branchless.
// The primitive C type MUST be unsigned.  It is currently a "char", which allows (at a minimum and in practice) 8 bits.
//
// A "useable bucket" is a bucket that is not in use (never populated), or has an age == 0.
//
// When an item is found in the cache, it's age is incremented.
// If a useable bucket hasn't been found, the current item (bucket) is aged along with two random items.
//
// If a value is not found in the cache, and no useable bucket has been found, that value is not added to the cache.

static void *SGJK_cachedObjects(SGJKParseState *parseState) {
  unsigned long  bucket     = parseState->token.value.hash & (parseState->cache.count - 1UL), setBucket = 0UL, useableBucket = 0UL, x = 0UL;
  void          *parsedAtom = NULL;
    
  if(SGJK_EXPECT_F(parseState->token.value.ptrRange.length == 0UL) && SGJK_EXPECT_T(parseState->token.value.type == SGJKValueTypeString)) { return(@""); }
  
  for(x = 0UL; x < SGJK_CACHE_PROBES; x++) {
    if(SGJK_EXPECT_F(parseState->cache.items[bucket].object == NULL)) { setBucket = 1UL; useableBucket = bucket; break; }
    
    if((SGJK_EXPECT_T(parseState->cache.items[bucket].hash == parseState->token.value.hash)) && (SGJK_EXPECT_T(parseState->cache.items[bucket].size == parseState->token.value.ptrRange.length)) && (SGJK_EXPECT_T(parseState->cache.items[bucket].type == parseState->token.value.type)) && (SGJK_EXPECT_T(parseState->cache.items[bucket].bytes != NULL)) && (SGJK_EXPECT_T(strncmp((const char *)parseState->cache.items[bucket].bytes, (const char *)parseState->token.value.ptrRange.ptr, parseState->token.value.ptrRange.length) == 0U))) {
      parseState->cache.age[bucket]     = (parseState->cache.age[bucket] << 1) | 1U;
      parseState->token.value.cacheItem = &parseState->cache.items[bucket];
      NSCParameterAssert(parseState->cache.items[bucket].object != NULL);
      return((void *)CFRetain(parseState->cache.items[bucket].object));
    } else {
      if(SGJK_EXPECT_F(setBucket == 0UL) && SGJK_EXPECT_F(parseState->cache.age[bucket] == 0U)) { setBucket = 1UL; useableBucket = bucket; }
      if(SGJK_EXPECT_F(setBucket == 0UL))                                                     { parseState->cache.age[bucket] >>= 1; SGJK_cache_age(parseState); SGJK_cache_age(parseState); }
      // This is the open addressing function.  The values length and type are used as a form of "double hashing" to distribute values with the same effective value hash across different object cache buckets.
      // The values type is a prime number that is relatively coprime to the other primes in the set of value types and the number of hash table buckets.
      bucket = (parseState->token.value.hash + (parseState->token.value.ptrRange.length * (x + 1UL)) + (parseState->token.value.type * (x + 1UL)) + (3UL * (x + 1UL))) & (parseState->cache.count - 1UL);
    }
  }
  
  switch(parseState->token.value.type) {
    case SGJKValueTypeString:           parsedAtom = (void *)CFStringCreateWithBytes(NULL, parseState->token.value.ptrRange.ptr, parseState->token.value.ptrRange.length, kCFStringEncodingUTF8, 0); break;
    case SGJKValueTypeLongLong:         parsedAtom = (void *)CFNumberCreate(NULL, kCFNumberLongLongType, &parseState->token.value.number.longLongValue);                                             break;
    case SGJKValueTypeUnsignedLongLong:
      if(parseState->token.value.number.unsignedLongLongValue <= LLONG_MAX) { parsedAtom = (void *)CFNumberCreate(NULL, kCFNumberLongLongType, &parseState->token.value.number.unsignedLongLongValue); }
      else { parsedAtom = (void *)parseState->objCImpCache.NSNumberInitWithUnsignedLongLong(parseState->objCImpCache.NSNumberAlloc(parseState->objCImpCache.NSNumberClass, @selector(alloc)), @selector(initWithUnsignedLongLong:), parseState->token.value.number.unsignedLongLongValue); }
      break;
    case SGJKValueTypeDouble:           parsedAtom = (void *)CFNumberCreate(NULL, kCFNumberDoubleType,   &parseState->token.value.number.doubleValue);                                               break;
    default: SGJK_error(parseState, @"Internal error: Unknown token value type. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); break;
  }
  
  if(SGJK_EXPECT_T(setBucket) && (SGJK_EXPECT_T(parsedAtom != NULL))) {
    bucket = useableBucket;
    if(SGJK_EXPECT_T((parseState->cache.items[bucket].object != NULL))) { CFRelease(parseState->cache.items[bucket].object); parseState->cache.items[bucket].object = NULL; }
    
    if(SGJK_EXPECT_T((parseState->cache.items[bucket].bytes = (unsigned char *)reallocf(parseState->cache.items[bucket].bytes, parseState->token.value.ptrRange.length)) != NULL)) {
      memcpy(parseState->cache.items[bucket].bytes, parseState->token.value.ptrRange.ptr, parseState->token.value.ptrRange.length);
      parseState->cache.items[bucket].object = (void *)CFRetain(parsedAtom);
      parseState->cache.items[bucket].hash   = parseState->token.value.hash;
      parseState->cache.items[bucket].cfHash = 0UL;
      parseState->cache.items[bucket].size   = parseState->token.value.ptrRange.length;
      parseState->cache.items[bucket].type   = parseState->token.value.type;
      parseState->token.value.cacheItem      = &parseState->cache.items[bucket];
      parseState->cache.age[bucket]          = SGJK_INIT_CACHE_AGE;
    } else { // The realloc failed, so clear the appropriate fields.
      parseState->cache.items[bucket].hash   = 0UL;
      parseState->cache.items[bucket].cfHash = 0UL;
      parseState->cache.items[bucket].size   = 0UL;
      parseState->cache.items[bucket].type   = 0UL;
    }
  }
  
  return(parsedAtom);
}


static void *SGJK_object_for_token(SGJKParseState *parseState) {
  void *parsedAtom = NULL;
  
  parseState->token.value.cacheItem = NULL;
  switch(parseState->token.type) {
    case SGJKTokenTypeString:      parsedAtom = SGJK_cachedObjects(parseState);    break;
    case SGJKTokenTypeNumber:      parsedAtom = SGJK_cachedObjects(parseState);    break;
    case SGJKTokenTypeObjectBegin: parsedAtom = SGJK_parse_dictionary(parseState); break;
    case SGJKTokenTypeArrayBegin:  parsedAtom = SGJK_parse_array(parseState);      break;
    case SGJKTokenTypeTrue:        parsedAtom = (void *)kCFBooleanTrue;          break;
    case SGJKTokenTypeFalse:       parsedAtom = (void *)kCFBooleanFalse;         break;
    case SGJKTokenTypeNull:        parsedAtom = (void *)kCFNull;                 break;
    default: SGJK_error(parseState, @"Internal error: Unknown token type. %@ line #%ld", [NSString stringWithUTF8String:__FILE__], (long)__LINE__); break;
  }
  
  return(parsedAtom);
}

#pragma mark -
@implementation SGJSONDecoder

+ (id)decoder
{
  return([self decoderWithParseOptions:SGJKParseOptionStrict]);
}

+ (id)decoderWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags
{
  return([[[self alloc] initWithParseOptions:parseOptionFlags] autorelease]);
}

- (id)init
{
  return([self initWithParseOptions:SGJKParseOptionStrict]);
}

- (id)initWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags
{
  if((self = [super init]) == NULL) { return(NULL); }

  if(parseOptionFlags & ~SGJKParseOptionValidFlags) { [self autorelease]; [NSException raise:NSInvalidArgumentException format:@"Invalid parse options."]; }

  if((parseState = (SGJKParseState *)calloc(1UL, sizeof(SGJKParseState))) == NULL) { goto errorExit; }

  parseState->parseOptionFlags = parseOptionFlags;
  
  parseState->token.tokenBuffer.roundSizeUpToMultipleOf = 4096UL;
  parseState->objectStack.roundSizeUpToMultipleOf       = 2048UL;

  parseState->objCImpCache.NSNumberClass                    = _SGJK_NSNumberClass;
  parseState->objCImpCache.NSNumberAlloc                    = _SGJK_NSNumberAllocImp;
  parseState->objCImpCache.NSNumberInitWithUnsignedLongLong = _SGJK_NSNumberInitWithUnsignedLongLongImp;
  
  parseState->cache.prng_lfsr = 1U;
  parseState->cache.count     = SGJK_CACHE_SLOTS;
  if((parseState->cache.items = (SGJKTokenCacheItem *)calloc(1UL, sizeof(SGJKTokenCacheItem) * parseState->cache.count)) == NULL) { goto errorExit; }

  return(self);

 errorExit:
  if(self) { [self autorelease]; self = NULL; }
  return(NULL);
}

// This is here primarily to support the NSString and NSData convenience functions so the autoreleased SGJSONDecoder can release most of its resources before the pool pops.
static void _JSONDecoderCleanup(SGJSONDecoder *decoder) {
  if((decoder != NULL) && (decoder->parseState != NULL)) {
    SGJK_managedBuffer_release(&decoder->parseState->token.tokenBuffer);
    SGJK_objectStack_release(&decoder->parseState->objectStack);
    
    [decoder clearCache];
    if(decoder->parseState->cache.items != NULL) { free(decoder->parseState->cache.items); decoder->parseState->cache.items = NULL; }
    
    free(decoder->parseState); decoder->parseState = NULL;
  }
}

- (void)dealloc
{
  _JSONDecoderCleanup(self);
  [super dealloc];
}

- (void)clearCache
{
  if(SGJK_EXPECT_T(parseState != NULL)) {
    if(SGJK_EXPECT_T(parseState->cache.items != NULL)) {
      size_t idx = 0UL;
      for(idx = 0UL; idx < parseState->cache.count; idx++) {
        if(SGJK_EXPECT_T(parseState->cache.items[idx].object != NULL)) { CFRelease(parseState->cache.items[idx].object); parseState->cache.items[idx].object = NULL; }
        if(SGJK_EXPECT_T(parseState->cache.items[idx].bytes  != NULL)) { free(parseState->cache.items[idx].bytes);       parseState->cache.items[idx].bytes  = NULL; }
        memset(&parseState->cache.items[idx], 0, sizeof(SGJKTokenCacheItem));
        parseState->cache.age[idx] = 0U;
      }
    }
  }
}

// This needs to be completely rewritten.
static id _SGJKParseUTF8String(SGJKParseState *parseState, BOOL mutableCollections, const unsigned char *string, size_t length, NSError **error) {
  NSCParameterAssert((parseState != NULL) && (string != NULL) && (parseState->cache.prng_lfsr != 0U));
  parseState->stringBuffer.bytes.ptr    = string;
  parseState->stringBuffer.bytes.length = length;
  parseState->atIndex                   = 0UL;
  parseState->lineNumber                = 1UL;
  parseState->lineStartIndex            = 0UL;
  parseState->prev_atIndex              = 0UL;
  parseState->prev_lineNumber           = 1UL;
  parseState->prev_lineStartIndex       = 0UL;
  parseState->error                     = NULL;
  parseState->errorIsPrev               = 0;
  parseState->mutableCollections        = (mutableCollections == NO) ? NO : YES;
  
  unsigned char stackTokenBuffer[SGJK_TOKENBUFFER_SIZE] SGJK_ALIGNED(64);
  SGJK_managedBuffer_setToStackBuffer(&parseState->token.tokenBuffer, stackTokenBuffer, sizeof(stackTokenBuffer));
  
  void       *stackObjects [SGJK_STACK_OBJS] SGJK_ALIGNED(64);
  void       *stackKeys    [SGJK_STACK_OBJS] SGJK_ALIGNED(64);
  CFHashCode  stackCFHashes[SGJK_STACK_OBJS] SGJK_ALIGNED(64);
  SGJK_objectStack_setToStackBuffer(&parseState->objectStack, stackObjects, stackKeys, stackCFHashes, SGJK_STACK_OBJS);
  
  id parsedJSON = json_parse_it(parseState);
  
  if((error != NULL) && (parseState->error != NULL)) { *error = parseState->error; }
  
  SGJK_managedBuffer_release(&parseState->token.tokenBuffer);
  SGJK_objectStack_release(&parseState->objectStack);
  
  parseState->stringBuffer.bytes.ptr    = NULL;
  parseState->stringBuffer.bytes.length = 0UL;
  parseState->atIndex                   = 0UL;
  parseState->lineNumber                = 1UL;
  parseState->lineStartIndex            = 0UL;
  parseState->prev_atIndex              = 0UL;
  parseState->prev_lineNumber           = 1UL;
  parseState->prev_lineStartIndex       = 0UL;
  parseState->error                     = NULL;
  parseState->errorIsPrev               = 0;
  parseState->mutableCollections        = NO;
  
  return(parsedJSON);
}

////////////
#pragma mark Deprecated as of v1.4
////////////

// Deprecated in JSONKit v1.4.  Use objectWithUTF8String:length: instead.
- (id)parseUTF8String:(const unsigned char *)string length:(size_t)length
{
  return([self objectWithUTF8String:string length:length error:NULL]);
}

// Deprecated in JSONKit v1.4.  Use objectWithUTF8String:length:error: instead.
- (id)parseUTF8String:(const unsigned char *)string length:(size_t)length error:(NSError **)error
{
  return([self objectWithUTF8String:string length:length error:error]);
}

// Deprecated in JSONKit v1.4.  Use objectWithData: instead.
- (id)parseJSONData:(NSData *)jsonData
{
  return([self objectWithData:jsonData error:NULL]);
}

// Deprecated in JSONKit v1.4.  Use objectWithData:error: instead.
- (id)parseJSONData:(NSData *)jsonData error:(NSError **)error
{
  return([self objectWithData:jsonData error:error]);
}

////////////
#pragma mark Methods that return immutable collection objects
////////////

- (id)objectWithUTF8String:(const unsigned char *)string length:(NSUInteger)length
{
  return([self objectWithUTF8String:string length:length error:NULL]);
}

- (id)objectWithUTF8String:(const unsigned char *)string length:(NSUInteger)length error:(NSError **)error
{
  if(parseState == NULL) { [NSException raise:NSInternalInconsistencyException format:@"parseState is NULL."];          }
  if(string     == NULL) { [NSException raise:NSInvalidArgumentException       format:@"The string argument is NULL."]; }
  
  return(_SGJKParseUTF8String(parseState, NO, string, (size_t)length, error));
}

- (id)objectWithData:(NSData *)jsonData
{
  return([self objectWithData:jsonData error:NULL]);
}

- (id)objectWithData:(NSData *)jsonData error:(NSError **)error
{
  if(jsonData == NULL) { [NSException raise:NSInvalidArgumentException format:@"The jsonData argument is NULL."]; }
  return([self objectWithUTF8String:(const unsigned char *)[jsonData bytes] length:[jsonData length] error:error]);
}

////////////
#pragma mark Methods that return mutable collection objects
////////////

- (id)mutableObjectWithUTF8String:(const unsigned char *)string length:(NSUInteger)length
{
  return([self mutableObjectWithUTF8String:string length:length error:NULL]);
}

- (id)mutableObjectWithUTF8String:(const unsigned char *)string length:(NSUInteger)length error:(NSError **)error
{
  if(parseState == NULL) { [NSException raise:NSInternalInconsistencyException format:@"parseState is NULL."];          }
  if(string     == NULL) { [NSException raise:NSInvalidArgumentException       format:@"The string argument is NULL."]; }
  
  return(_SGJKParseUTF8String(parseState, YES, string, (size_t)length, error));
}

- (id)mutableObjectWithData:(NSData *)jsonData
{
  return([self mutableObjectWithData:jsonData error:NULL]);
}

- (id)mutableObjectWithData:(NSData *)jsonData error:(NSError **)error
{
  if(jsonData == NULL) { [NSException raise:NSInvalidArgumentException format:@"The jsonData argument is NULL."]; }
  return([self mutableObjectWithUTF8String:(const unsigned char *)[jsonData bytes] length:[jsonData length] error:error]);
}

@end

/*
 The NSString and NSData convenience methods need a little bit of explanation.
 
 Prior to JSONKit v1.4, the NSString -objectFromJSONStringWithParseOptions:error: method looked like
 
 const unsigned char *utf8String = (const unsigned char *)[self UTF8String];
 if(utf8String == NULL) { return(NULL); }
 size_t               utf8Length = strlen((const char *)utf8String); 
 return([[SGJSONDecoder decoderWithParseOptions:parseOptionFlags] parseUTF8String:utf8String length:utf8Length error:error]);
 
 This changed with v1.4 to a more complicated method.  The reason for this is to keep the amount of memory that is
 allocated, but not yet freed because it is dependent on the autorelease pool to pop before it can be reclaimed.
 
 In the simpler v1.3 code, this included all the bytes used to store the -UTF8String along with the SGJSONDecoder and all its overhead.
 
 Now we use an autoreleased CFMutableData that is sized to the UTF8 length of the NSString in question and is used to hold the UTF8
 conversion of said string.
 
 Once parsed, the CFMutableData has its length set to 0.  This should, hopefully, allow the CFMutableData to realloc and/or free
 the buffer.
 
 Another change made was a slight modification to SGJSONDecoder so that most of the cleanup work that was done in -dealloc was moved
 to a private, internal function.  These convenience routines keep the pointer to the autoreleased SGJSONDecoder and calls
 _JSONDecoderCleanup() to early release the decoders resources since we already know that particular decoder is not going to be used
 again.  
 
 If everything goes smoothly, this will most likely result in perhaps a few hundred bytes that are allocated but waiting for the
 autorelease pool to pop.  This is compared to the thousands and eSGASIly hundreds of thousands of bytes that would have been in
 autorelease limbo.  It's more complicated for us, but a win for the user.
 
 Autorelease objects are used in case things don't go smoothly.  By having them autoreleased, we effectively guarantee that our
 requirement to -release the object is always met, not matter what goes wrong.  The downside is having a an object or two in
 autorelease limbo, but we've done our best to minimize that impact, so it all balances out.
 */

@implementation NSString (SGJSONKitDeserializing)

static id _NSStringObjectFromJSONString(NSString *jsonString, SGJKParseOptionFlags parseOptionFlags, NSError **error, BOOL mutableCollection) {
  id                returnObject = NULL;
  CFMutableDataRef  mutableData  = NULL;
  SGJSONDecoder      *decoder      = NULL;
  
  CFIndex    stringLength     = CFStringGetLength((CFStringRef)jsonString);
  NSUInteger stringUTF8Length = [jsonString lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  
  if((mutableData = (CFMutableDataRef)[(id)CFDataCreateMutable(NULL, (NSUInteger)stringUTF8Length) autorelease]) != NULL) {
    UInt8   *utf8String = CFDataGetMutableBytePtr(mutableData);
    CFIndex  usedBytes  = 0L, convertedCount = 0L;
    
    convertedCount = CFStringGetBytes((CFStringRef)jsonString, CFRangeMake(0L, stringLength), kCFStringEncodingUTF8, '?', NO, utf8String, (NSUInteger)stringUTF8Length, &usedBytes);
    if(SGJK_EXPECT_F(convertedCount != stringLength) || SGJK_EXPECT_F(usedBytes < 0L)) { if(error != NULL) { *error = [NSError errorWithDomain:@"SGJKErrorDomain" code:-1L userInfo:[NSDictionary dictionaryWithObject:@"An error occurred converting the contents of a NSString to UTF8." forKey:NSLocalizedDescriptionKey]]; } goto exitNow; }
    
    if(mutableCollection == NO) { returnObject = [(decoder = [SGJSONDecoder decoderWithParseOptions:parseOptionFlags])        objectWithUTF8String:(const unsigned char *)utf8String length:(size_t)usedBytes error:error]; }
    else                        { returnObject = [(decoder = [SGJSONDecoder decoderWithParseOptions:parseOptionFlags]) mutableObjectWithUTF8String:(const unsigned char *)utf8String length:(size_t)usedBytes error:error]; }
  }
  
exitNow:
  if(mutableData != NULL) { CFDataSetLength(mutableData, 0L); }
  if(decoder     != NULL) { _JSONDecoderCleanup(decoder);     }
  return(returnObject);
}

- (id)objectFromJSONString
{
  return([self objectFromJSONStringWithParseOptions:SGJKParseOptionStrict error:NULL]);
}

- (id)objectFromJSONStringWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags
{
  return([self objectFromJSONStringWithParseOptions:parseOptionFlags error:NULL]);
}

- (id)objectFromJSONStringWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags error:(NSError **)error
{
  return(_NSStringObjectFromJSONString(self, parseOptionFlags, error, NO));
}


- (id)mutableObjectFromJSONString
{
  return([self mutableObjectFromJSONStringWithParseOptions:SGJKParseOptionStrict error:NULL]);
}

- (id)mutableObjectFromJSONStringWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags
{
  return([self mutableObjectFromJSONStringWithParseOptions:parseOptionFlags error:NULL]);
}

- (id)mutableObjectFromJSONStringWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags error:(NSError **)error
{
  return(_NSStringObjectFromJSONString(self, parseOptionFlags, error, YES));
}

@end

@implementation NSData (SGJSONKitDeserializing)

- (id)objectFromJSONData
{
  return([self objectFromJSONDataWithParseOptions:SGJKParseOptionStrict error:NULL]);
}

- (id)objectFromJSONDataWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags
{
  return([self objectFromJSONDataWithParseOptions:parseOptionFlags error:NULL]);
}

- (id)objectFromJSONDataWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags error:(NSError **)error
{
  SGJSONDecoder *decoder = NULL;
  id returnObject = [(decoder = [SGJSONDecoder decoderWithParseOptions:parseOptionFlags]) objectWithData:self error:error];
  if(decoder != NULL) { _JSONDecoderCleanup(decoder); }
  return(returnObject);
}

- (id)mutableObjectFromJSONData
{
  return([self mutableObjectFromJSONDataWithParseOptions:SGJKParseOptionStrict error:NULL]);
}

- (id)mutableObjectFromJSONDataWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags
{
  return([self mutableObjectFromJSONDataWithParseOptions:parseOptionFlags error:NULL]);
}

- (id)mutableObjectFromJSONDataWithParseOptions:(SGJKParseOptionFlags)parseOptionFlags error:(NSError **)error
{
  SGJSONDecoder *decoder = NULL;
  id returnObject = [(decoder = [SGJSONDecoder decoderWithParseOptions:parseOptionFlags]) mutableObjectWithData:self error:error];
  if(decoder != NULL) { _JSONDecoderCleanup(decoder); }
  return(returnObject);
}


@end

////////////
#pragma mark -
#pragma mark Encoding / deserializing functions

static void SGJK_encode_error(SGJKEncodeState *encodeState, NSString *format, ...) {
  NSCParameterAssert((encodeState != NULL) && (format != NULL));

  va_list varArgsList;
  va_start(varArgsList, format);
  NSString *formatString = [[[NSString alloc] initWithFormat:format arguments:varArgsList] autorelease];
  va_end(varArgsList);

  if(encodeState->error == NULL) {
    encodeState->error = [NSError errorWithDomain:@"SGJKErrorDomain" code:-1L userInfo:
                                   [NSDictionary dictionaryWithObjectsAndKeys:
                                                                              formatString, NSLocalizedDescriptionKey,
                                                                              NULL]];
  }
}

SGJK_STATIC_INLINE void SGJK_encode_updateCache(SGJKEncodeState *encodeState, SGJKEncodeCache *cacheSlot, size_t startingAtIndex, id object) {
  NSCParameterAssert(encodeState != NULL);
  if(SGJK_EXPECT_T(cacheSlot != NULL)) {
    NSCParameterAssert((object != NULL) && (startingAtIndex <= encodeState->atIndex));
    cacheSlot->object = object;
    cacheSlot->offset = startingAtIndex;
    cacheSlot->length = (size_t)(encodeState->atIndex - startingAtIndex);  
  }
}

static int SGJK_encode_printf(SGJKEncodeState *encodeState, SGJKEncodeCache *cacheSlot, size_t startingAtIndex, id object, const char *format, ...) {
  va_list varArgsList, varArgsListCopy;
  va_start(varArgsList, format);
  va_copy(varArgsListCopy, varArgsList);

  NSCParameterAssert((encodeState != NULL) && (encodeState->atIndex < encodeState->stringBuffer.bytes.length) && (startingAtIndex <= encodeState->atIndex) && (format != NULL));

  ssize_t  formattedStringLength = 0L;
  int      returnValue           = 0;

  if(SGJK_EXPECT_T((formattedStringLength = vsnprintf((char *)&encodeState->stringBuffer.bytes.ptr[encodeState->atIndex], (encodeState->stringBuffer.bytes.length - encodeState->atIndex), format, varArgsList)) >= (ssize_t)(encodeState->stringBuffer.bytes.length - encodeState->atIndex))) {
    NSCParameterAssert(((encodeState->atIndex + (formattedStringLength * 2UL) + 256UL) > encodeState->stringBuffer.bytes.length));
    if(SGJK_EXPECT_F(((encodeState->atIndex + (formattedStringLength * 2UL) + 256UL) > encodeState->stringBuffer.bytes.length)) && SGJK_EXPECT_F((SGJK_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + (formattedStringLength * 2UL)+ 4096UL) == NULL))) { SGJK_encode_error(encodeState, @"Unable to resize temporary buffer."); returnValue = 1; goto exitNow; }
    if(SGJK_EXPECT_F((formattedStringLength = vsnprintf((char *)&encodeState->stringBuffer.bytes.ptr[encodeState->atIndex], (encodeState->stringBuffer.bytes.length - encodeState->atIndex), format, varArgsListCopy)) >= (ssize_t)(encodeState->stringBuffer.bytes.length - encodeState->atIndex))) { SGJK_encode_error(encodeState, @"vsnprintf failed unexpectedly."); returnValue = 1; goto exitNow; }
  }
  
exitNow:
  va_end(varArgsList);
  va_end(varArgsListCopy);
  if(SGJK_EXPECT_T(returnValue == 0)) { encodeState->atIndex += formattedStringLength; SGJK_encode_updateCache(encodeState, cacheSlot, startingAtIndex, object); }
  return(returnValue);
}

static int SGJK_encode_write(SGJKEncodeState *encodeState, SGJKEncodeCache *cacheSlot, size_t startingAtIndex, id object, const char *format) {
  NSCParameterAssert((encodeState != NULL) && (encodeState->atIndex < encodeState->stringBuffer.bytes.length) && (startingAtIndex <= encodeState->atIndex) && (format != NULL));
  if(SGJK_EXPECT_F(((encodeState->atIndex + strlen(format) + 256UL) > encodeState->stringBuffer.bytes.length)) && SGJK_EXPECT_F((SGJK_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + strlen(format) + 1024UL) == NULL))) { SGJK_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }

  size_t formatIdx = 0UL;
  for(formatIdx = 0UL; format[formatIdx] != 0; formatIdx++) { NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length); encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = format[formatIdx]; }
  SGJK_encode_updateCache(encodeState, cacheSlot, startingAtIndex, object);
  return(0);
}

static int SGJK_encode_writePrettyPrintWhiteSpace(SGJKEncodeState *encodeState) {
  NSCParameterAssert((encodeState != NULL) && ((encodeState->serializeOptionFlags & SGJKSerializeOptionPretty) != 0UL));
  if(SGJK_EXPECT_F((encodeState->atIndex + ((encodeState->depth + 1UL) * 2UL) + 16UL) > encodeState->stringBuffer.bytes.length) && SGJK_EXPECT_T(SGJK_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + ((encodeState->depth + 1UL) * 2UL) + 4096UL) == NULL)) { SGJK_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }
  encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\n';
  size_t depthWhiteSpace = 0UL;
  for(depthWhiteSpace = 0UL; depthWhiteSpace < (encodeState->depth * 2UL); depthWhiteSpace++) { NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length); encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = ' '; }
  return(0);
}  

static int SGJK_encode_write1slow(SGJKEncodeState *encodeState, ssize_t depthChange, const char *format) {
  NSCParameterAssert((encodeState != NULL) && (encodeState->atIndex < encodeState->stringBuffer.bytes.length) && (format != NULL) && ((depthChange >= -1L) && (depthChange <= 1L)) && ((encodeState->depth == 0UL) ? (depthChange >= 0L) : 1) && ((encodeState->serializeOptionFlags & SGJKSerializeOptionPretty) != 0UL));
  if(SGJK_EXPECT_F((encodeState->atIndex + ((encodeState->depth + 1UL) * 2UL) + 16UL) > encodeState->stringBuffer.bytes.length) && SGJK_EXPECT_F(SGJK_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + ((encodeState->depth + 1UL) * 2UL) + 4096UL) == NULL)) { SGJK_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }
  encodeState->depth += depthChange;
  if(SGJK_EXPECT_T(format[0] == ':')) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = format[0]; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = ' '; }
  else {
    if(SGJK_EXPECT_F(depthChange == -1L)) { if(SGJK_EXPECT_F(SGJK_encode_writePrettyPrintWhiteSpace(encodeState))) { return(1); } }
    encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = format[0];
    if(SGJK_EXPECT_T(depthChange != -1L)) { if(SGJK_EXPECT_F(SGJK_encode_writePrettyPrintWhiteSpace(encodeState))) { return(1); } }
  }
  NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length);
  return(0);
}

static int SGJK_encode_write1fast(SGJKEncodeState *encodeState, ssize_t depthChange SGJK_UNUSED_ARG, const char *format) {
  NSCParameterAssert((encodeState != NULL) && (encodeState->atIndex < encodeState->stringBuffer.bytes.length) && ((encodeState->serializeOptionFlags & SGJKSerializeOptionPretty) == 0UL));
  if(SGJK_EXPECT_T((encodeState->atIndex + 4UL) < encodeState->stringBuffer.bytes.length)) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = format[0]; }
  else { return(SGJK_encode_write(encodeState, NULL, 0UL, NULL, format)); }
  return(0);
}

static int SGJK_encode_writen(SGJKEncodeState *encodeState, SGJKEncodeCache *cacheSlot, size_t startingAtIndex, id object, const char *format, size_t length) {
  NSCParameterAssert((encodeState != NULL) && (encodeState->atIndex < encodeState->stringBuffer.bytes.length) && (startingAtIndex <= encodeState->atIndex));
  if(SGJK_EXPECT_F((encodeState->stringBuffer.bytes.length - encodeState->atIndex) < (length + 4UL))) { if(SGJK_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + 4096UL + length) == NULL) { SGJK_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); } }
  memcpy(encodeState->stringBuffer.bytes.ptr + encodeState->atIndex, format, length);
  encodeState->atIndex += length;
  SGJK_encode_updateCache(encodeState, cacheSlot, startingAtIndex, object);
  return(0);
}

SGJK_STATIC_INLINE SGJKHash SGJK_encode_object_hash(void *objectPtr) {
  return( ( (((SGJKHash)objectPtr) >> 21) ^ (((SGJKHash)objectPtr) >> 9)   ) + (((SGJKHash)objectPtr) >> 4) );
}

static int SGJK_encode_add_atom_to_buffer(SGJKEncodeState *encodeState, void *objectPtr) {
  NSCParameterAssert((encodeState != NULL) && (encodeState->atIndex < encodeState->stringBuffer.bytes.length) && (objectPtr != NULL));

  id     object          = (id)objectPtr, encodeCacheObject = object;
  int    isClass         = SGJKClassUnknown;
  size_t startingAtIndex = encodeState->atIndex;

  SGJKHash         objectHash = SGJK_encode_object_hash(objectPtr);
  SGJKEncodeCache *cacheSlot  = &encodeState->cache[objectHash % SGJK_ENCODE_CACHE_SLOTS];

  if(SGJK_EXPECT_T(cacheSlot->object == object)) {
    NSCParameterAssert((cacheSlot->object != NULL) &&
                       (cacheSlot->offset < encodeState->atIndex)                   && ((cacheSlot->offset + cacheSlot->length) < encodeState->atIndex)                                    &&
                       (cacheSlot->offset < encodeState->stringBuffer.bytes.length) && ((cacheSlot->offset + cacheSlot->length) < encodeState->stringBuffer.bytes.length)                  &&
                       ((encodeState->stringBuffer.bytes.ptr + encodeState->atIndex)                     < (encodeState->stringBuffer.bytes.ptr + encodeState->stringBuffer.bytes.length)) &&
                       ((encodeState->stringBuffer.bytes.ptr + cacheSlot->offset)                        < (encodeState->stringBuffer.bytes.ptr + encodeState->stringBuffer.bytes.length)) &&
                       ((encodeState->stringBuffer.bytes.ptr + cacheSlot->offset + cacheSlot->length)    < (encodeState->stringBuffer.bytes.ptr + encodeState->stringBuffer.bytes.length)));
    if(SGJK_EXPECT_F(((encodeState->atIndex + cacheSlot->length + 256UL) > encodeState->stringBuffer.bytes.length)) && SGJK_EXPECT_F((SGJK_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + cacheSlot->length + 1024UL) == NULL))) { SGJK_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }
    NSCParameterAssert(((encodeState->atIndex + cacheSlot->length) < encodeState->stringBuffer.bytes.length) &&
                       ((encodeState->stringBuffer.bytes.ptr + encodeState->atIndex)                     < (encodeState->stringBuffer.bytes.ptr + encodeState->stringBuffer.bytes.length)) &&
                       ((encodeState->stringBuffer.bytes.ptr + encodeState->atIndex + cacheSlot->length) < (encodeState->stringBuffer.bytes.ptr + encodeState->stringBuffer.bytes.length)) &&
                       ((encodeState->stringBuffer.bytes.ptr + cacheSlot->offset)                        < (encodeState->stringBuffer.bytes.ptr + encodeState->stringBuffer.bytes.length)) &&
                       ((encodeState->stringBuffer.bytes.ptr + cacheSlot->offset + cacheSlot->length)    < (encodeState->stringBuffer.bytes.ptr + encodeState->stringBuffer.bytes.length)) &&
                       ((encodeState->stringBuffer.bytes.ptr + cacheSlot->offset + cacheSlot->length)    < (encodeState->stringBuffer.bytes.ptr + encodeState->atIndex)));
    memcpy(encodeState->stringBuffer.bytes.ptr + encodeState->atIndex, encodeState->stringBuffer.bytes.ptr + cacheSlot->offset, cacheSlot->length);
    encodeState->atIndex += cacheSlot->length;
    return(0);
  }

  // When we encounter a class that we do not handle, and we have either a delegate or block that the user supplied to format unsupported classes,
  // we "re-run" the object check.  However, we re-run the object check exactly ONCE.  If the user supplies an object that isn't one of the
  // supported classes, we fail the second type (i.e., double fault error).
  BOOL rerunningAfterClassFormatter = NO;
rerunAfterClassFormatter:
       if(SGJK_EXPECT_T(object->isa == encodeState->fastClassLookup.stringClass))     { isClass = SGJKClassString;     }
  else if(SGJK_EXPECT_T(object->isa == encodeState->fastClassLookup.numberClass))     { isClass = SGJKClassNumber;     }
  else if(SGJK_EXPECT_T(object->isa == encodeState->fastClassLookup.dictionaryClass)) { isClass = SGJKClassDictionary; }
  else if(SGJK_EXPECT_T(object->isa == encodeState->fastClassLookup.arrayClass))      { isClass = SGJKClassArray;      }
  else if(SGJK_EXPECT_T(object->isa == encodeState->fastClassLookup.nullClass))       { isClass = SGJKClassNull;       }
  else {
         if(SGJK_EXPECT_T([object isKindOfClass:[NSString     class]])) { encodeState->fastClassLookup.stringClass     = object->isa; isClass = SGJKClassString;     }
    else if(SGJK_EXPECT_T([object isKindOfClass:[NSNumber     class]])) { encodeState->fastClassLookup.numberClass     = object->isa; isClass = SGJKClassNumber;     }
    else if(SGJK_EXPECT_T([object isKindOfClass:[NSDictionary class]])) { encodeState->fastClassLookup.dictionaryClass = object->isa; isClass = SGJKClassDictionary; }
    else if(SGJK_EXPECT_T([object isKindOfClass:[NSArray      class]])) { encodeState->fastClassLookup.arrayClass      = object->isa; isClass = SGJKClassArray;      }
    else if(SGJK_EXPECT_T([object isKindOfClass:[NSNull       class]])) { encodeState->fastClassLookup.nullClass       = object->isa; isClass = SGJKClassNull;       }
    else {
      if((rerunningAfterClassFormatter == NO) && (
#ifdef __BLOCKS__
           ((encodeState->classFormatterBlock) && ((object = encodeState->classFormatterBlock(object))                                                                         != NULL)) ||
#endif
           ((encodeState->classFormatterIMP)   && ((object = encodeState->classFormatterIMP(encodeState->classFormatterDelegate, encodeState->classFormatterSelector, object)) != NULL))    )) { rerunningAfterClassFormatter = YES; goto rerunAfterClassFormatter; }
      
      if(rerunningAfterClassFormatter == NO) { SGJK_encode_error(encodeState, @"Unable to serialize object class %@.", NSStringFromClass([encodeCacheObject class])); return(1); }
      else { SGJK_encode_error(encodeState, @"Unable to serialize object class %@ that was returned by the unsupported class formatter.  Original object class was %@.", (object == NULL) ? @"NULL" : NSStringFromClass([object class]), NSStringFromClass([encodeCacheObject class])); return(1); }
    }
  }

  // This is here for the benefit of the optimizer.  It allows the optimizer to do loop invariant code motion for the SGJKClassArray
  // and SGJKClassDictionary cases when printing simple, single characters via SGJK_encode_write(), which is actually a macro:
  // #define SGJK_encode_write1(es, dc, f) (_SGJK_encode_prettyPrint ? SGJK_encode_write1slow(es, dc, f) : SGJK_encode_write1fast(es, dc, f))
  int _SGJK_encode_prettyPrint = SGJK_EXPECT_T((encodeState->serializeOptionFlags & SGJKSerializeOptionPretty) == 0) ? 0 : 1;
  
  switch(isClass) {
    case SGJKClassString:
      {
        {
          const unsigned char *cStringPtr = (const unsigned char *)CFStringGetCStringPtr((CFStringRef)object, kCFStringEncodingMacRoman);
          if(cStringPtr != NULL) {
            const unsigned char *utf8String = cStringPtr;
            size_t               utf8Idx    = 0UL;

            CFIndex stringLength = CFStringGetLength((CFStringRef)object);
            if(SGJK_EXPECT_F(((encodeState->atIndex + (stringLength * 2UL) + 256UL) > encodeState->stringBuffer.bytes.length)) && SGJK_EXPECT_F((SGJK_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + (stringLength * 2UL) + 1024UL) == NULL))) { SGJK_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }

            if(SGJK_EXPECT_T((encodeState->encodeOption & SGJKEncodeOptionStringObjTrimQuotes) == 0UL)) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\"'; }
            for(utf8Idx = 0UL; utf8String[utf8Idx] != 0U; utf8Idx++) {
              NSCParameterAssert(((&encodeState->stringBuffer.bytes.ptr[encodeState->atIndex]) - encodeState->stringBuffer.bytes.ptr) < (ssize_t)encodeState->stringBuffer.bytes.length);
              NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length);
              if(SGJK_EXPECT_F(utf8String[utf8Idx] >= 0x80U)) { encodeState->atIndex = startingAtIndex; goto slowUTF8Path; }
              if(SGJK_EXPECT_F(utf8String[utf8Idx] <  0x20U)) {
                switch(utf8String[utf8Idx]) {
                  case '\b': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'b'; break;
                  case '\f': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'f'; break;
                  case '\n': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'n'; break;
                  case '\r': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'r'; break;
                  case '\t': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 't'; break;
                  default: if(SGJK_EXPECT_F(SGJK_encode_printf(encodeState, NULL, 0UL, NULL, "\\u%4.4x", utf8String[utf8Idx]))) { return(1); } break;
                }
              } else {
                if(SGJK_EXPECT_F(utf8String[utf8Idx] == '\"') || SGJK_EXPECT_F(utf8String[utf8Idx] == '\\') || (SGJK_EXPECT_F(encodeState->serializeOptionFlags & SGJKSerializeOptionEscapeForwardSlashes) && SGJK_EXPECT_F(utf8String[utf8Idx] == '/'))) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; }
                encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = utf8String[utf8Idx];
              }
            }
            NSCParameterAssert((encodeState->atIndex + 1UL) < encodeState->stringBuffer.bytes.length);
            if(SGJK_EXPECT_T((encodeState->encodeOption & SGJKEncodeOptionStringObjTrimQuotes) == 0UL)) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\"'; }
            SGJK_encode_updateCache(encodeState, cacheSlot, startingAtIndex, encodeCacheObject);
            return(0);
          }
        }

      slowUTF8Path:
        {
          CFIndex stringLength        = CFStringGetLength((CFStringRef)object);
          CFIndex maxStringUTF8Length = CFStringGetMaximumSizeForEncoding(stringLength, kCFStringEncodingUTF8) + 32L;
        
          if(SGJK_EXPECT_F((size_t)maxStringUTF8Length > encodeState->utf8ConversionBuffer.bytes.length) && SGJK_EXPECT_F(SGJK_managedBuffer_resize(&encodeState->utf8ConversionBuffer, maxStringUTF8Length + 1024UL) == NULL)) { SGJK_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }
        
          CFIndex usedBytes = 0L, convertedCount = 0L;
          convertedCount = CFStringGetBytes((CFStringRef)object, CFRangeMake(0L, stringLength), kCFStringEncodingUTF8, '?', NO, encodeState->utf8ConversionBuffer.bytes.ptr, encodeState->utf8ConversionBuffer.bytes.length - 16L, &usedBytes);
          if(SGJK_EXPECT_F(convertedCount != stringLength) || SGJK_EXPECT_F(usedBytes < 0L)) { SGJK_encode_error(encodeState, @"An error occurred converting the contents of a NSString to UTF8."); return(1); }
        
          if(SGJK_EXPECT_F((encodeState->atIndex + (maxStringUTF8Length * 2UL) + 256UL) > encodeState->stringBuffer.bytes.length) && SGJK_EXPECT_F(SGJK_managedBuffer_resize(&encodeState->stringBuffer, encodeState->atIndex + (maxStringUTF8Length * 2UL) + 1024UL) == NULL)) { SGJK_encode_error(encodeState, @"Unable to resize temporary buffer."); return(1); }
        
          const unsigned char *utf8String = encodeState->utf8ConversionBuffer.bytes.ptr;
        
          size_t utf8Idx = 0UL;
          if(SGJK_EXPECT_T((encodeState->encodeOption & SGJKEncodeOptionStringObjTrimQuotes) == 0UL)) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\"'; }
          for(utf8Idx = 0UL; utf8Idx < (size_t)usedBytes; utf8Idx++) {
            NSCParameterAssert(((&encodeState->stringBuffer.bytes.ptr[encodeState->atIndex]) - encodeState->stringBuffer.bytes.ptr) < (ssize_t)encodeState->stringBuffer.bytes.length);
            NSCParameterAssert(encodeState->atIndex < encodeState->stringBuffer.bytes.length);
            NSCParameterAssert((CFIndex)utf8Idx < usedBytes);
            if(SGJK_EXPECT_F(utf8String[utf8Idx] < 0x20U)) {
              switch(utf8String[utf8Idx]) {
                case '\b': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'b'; break;
                case '\f': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'f'; break;
                case '\n': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'n'; break;
                case '\r': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 'r'; break;
                case '\t': encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = 't'; break;
                default: if(SGJK_EXPECT_F(SGJK_encode_printf(encodeState, NULL, 0UL, NULL, "\\u%4.4x", utf8String[utf8Idx]))) { return(1); } break;
              }
            } else {
              if(SGJK_EXPECT_F(utf8String[utf8Idx] >= 0x80U) && (encodeState->serializeOptionFlags & SGJKSerializeOptionEscapeUnicode)) {
                const unsigned char *nextValidCharacter = NULL;
                UTF32                u32ch              = 0U;
                ConversionResult     result;

                if(SGJK_EXPECT_F((result = ConvertSingleCodePointInUTF8(&utf8String[utf8Idx], &utf8String[usedBytes], (UTF8 const **)&nextValidCharacter, &u32ch)) != conversionOK)) { SGJK_encode_error(encodeState, @"Error converting UTF8."); return(1); }
                else {
                  utf8Idx = (nextValidCharacter - utf8String) - 1UL;
                  if(SGJK_EXPECT_T(u32ch <= 0xffffU)) { if(SGJK_EXPECT_F(SGJK_encode_printf(encodeState, NULL, 0UL, NULL, "\\u%4.4x", u32ch)))                                                           { return(1); } }
                  else                              { if(SGJK_EXPECT_F(SGJK_encode_printf(encodeState, NULL, 0UL, NULL, "\\u%4.4x\\u%4.4x", (0xd7c0U + (u32ch >> 10)), (0xdc00U + (u32ch & 0x3ffU))))) { return(1); } }
                }
              } else {
                if(SGJK_EXPECT_F(utf8String[utf8Idx] == '\"') || SGJK_EXPECT_F(utf8String[utf8Idx] == '\\') || (SGJK_EXPECT_F(encodeState->serializeOptionFlags & SGJKSerializeOptionEscapeForwardSlashes) && SGJK_EXPECT_F(utf8String[utf8Idx] == '/'))) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\\'; }
                encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = utf8String[utf8Idx];
              }
            }
          }
          NSCParameterAssert((encodeState->atIndex + 1UL) < encodeState->stringBuffer.bytes.length);
          if(SGJK_EXPECT_T((encodeState->encodeOption & SGJKEncodeOptionStringObjTrimQuotes) == 0UL)) { encodeState->stringBuffer.bytes.ptr[encodeState->atIndex++] = '\"'; }
          SGJK_encode_updateCache(encodeState, cacheSlot, startingAtIndex, encodeCacheObject);
          return(0);
        }
      }
      break;

    case SGJKClassNumber:
      {
             if(object == (id)kCFBooleanTrue)  { return(SGJK_encode_writen(encodeState, cacheSlot, startingAtIndex, encodeCacheObject, "true",  4UL)); }
        else if(object == (id)kCFBooleanFalse) { return(SGJK_encode_writen(encodeState, cacheSlot, startingAtIndex, encodeCacheObject, "false", 5UL)); }
        
        const char         *objCType = [object objCType];
        char                anum[256], *aptr = &anum[255];
        int                 isNegative = 0;
        unsigned long long  ullv;
        long long           llv;
        
        if(SGJK_EXPECT_F(objCType == NULL) || SGJK_EXPECT_F(objCType[0] == 0) || SGJK_EXPECT_F(objCType[1] != 0)) { SGJK_encode_error(encodeState, @"NSNumber conversion error, unknown type.  Type: '%s'", (objCType == NULL) ? "<NULL>" : objCType); return(1); }
        
        switch(objCType[0]) {
          case 'c': case 'i': case 's': case 'l': case 'q':
            if(SGJK_EXPECT_T(CFNumberGetValue((CFNumberRef)object, kCFNumberLongLongType, &llv)))  {
              if(llv < 0LL)  { ullv = -llv; isNegative = 1; } else { ullv = llv; isNegative = 0; }
              goto convertNumber;
            } else { SGJK_encode_error(encodeState, @"Unable to get scalar value from number object."); return(1); }
            break;
          case 'C': case 'I': case 'S': case 'L': case 'Q': case 'B':
            if(SGJK_EXPECT_T(CFNumberGetValue((CFNumberRef)object, kCFNumberLongLongType, &ullv))) {
            convertNumber:
              if(SGJK_EXPECT_F(ullv < 10ULL)) { *--aptr = ullv + '0'; } else { while(SGJK_EXPECT_T(ullv > 0ULL)) { *--aptr = (ullv % 10ULL) + '0'; ullv /= 10ULL; NSCParameterAssert(aptr > anum); } }
              if(isNegative) { *--aptr = '-'; }
              NSCParameterAssert(aptr > anum);
              return(SGJK_encode_writen(encodeState, cacheSlot, startingAtIndex, encodeCacheObject, aptr, &anum[255] - aptr));
            } else { SGJK_encode_error(encodeState, @"Unable to get scalar value from number object."); return(1); }
            break;
          case 'f': case 'd':
            {
              double dv;
              if(SGJK_EXPECT_T(CFNumberGetValue((CFNumberRef)object, kCFNumberDoubleType, &dv))) {
                if(SGJK_EXPECT_F(!isfinite(dv))) { SGJK_encode_error(encodeState, @"Floating point values must be finite.  JSON does not support NaN or Infinity."); return(1); }
                return(SGJK_encode_printf(encodeState, cacheSlot, startingAtIndex, encodeCacheObject, "%.17g", dv));
              } else { SGJK_encode_error(encodeState, @"Unable to get floating point value from number object."); return(1); }
            }
            break;
          default: SGJK_encode_error(encodeState, @"NSNumber conversion error, unknown type.  Type: '%c' / 0x%2.2x", objCType[0], objCType[0]); return(1); break;
        }
      }
      break;
    
    case SGJKClassArray:
      {
        int     printComma = 0;
        CFIndex arrayCount = CFArrayGetCount((CFArrayRef)object), idx = 0L;
        if(SGJK_EXPECT_F(SGJK_encode_write1(encodeState, 1L, "["))) { return(1); }
        if(SGJK_EXPECT_F(arrayCount > 1020L)) {
          for(id arrayObject in object)          { if(SGJK_EXPECT_T(printComma)) { if(SGJK_EXPECT_F(SGJK_encode_write1(encodeState, 0L, ","))) { return(1); } } printComma = 1; if(SGJK_EXPECT_F(SGJK_encode_add_atom_to_buffer(encodeState, arrayObject)))  { return(1); } }
        } else {
          void *objects[1024];
          CFArrayGetValues((CFArrayRef)object, CFRangeMake(0L, arrayCount), (const void **)objects);
          for(idx = 0L; idx < arrayCount; idx++) { if(SGJK_EXPECT_T(printComma)) { if(SGJK_EXPECT_F(SGJK_encode_write1(encodeState, 0L, ","))) { return(1); } } printComma = 1; if(SGJK_EXPECT_F(SGJK_encode_add_atom_to_buffer(encodeState, objects[idx]))) { return(1); } }
        }
        return(SGJK_encode_write1(encodeState, -1L, "]"));
      }
      break;

    case SGJKClassDictionary:
      {
        int     printComma      = 0;
        CFIndex dictionaryCount = CFDictionaryGetCount((CFDictionaryRef)object), idx = 0L;
        id      enumerateObject = SGJK_EXPECT_F(_SGJK_encode_prettyPrint) ? [[object allKeys] sortedArrayUsingSelector:@selector(compare:)] : object;

        if(SGJK_EXPECT_F(SGJK_encode_write1(encodeState, 1L, "{"))) { return(1); }
        if(SGJK_EXPECT_F(_SGJK_encode_prettyPrint) || SGJK_EXPECT_F(dictionaryCount > 1020L)) {
          for(id keyObject in enumerateObject) {
            if(SGJK_EXPECT_T(printComma)) { if(SGJK_EXPECT_F(SGJK_encode_write1(encodeState, 0L, ","))) { return(1); } }
            printComma = 1;
            if(SGJK_EXPECT_F((keyObject->isa      != encodeState->fastClassLookup.stringClass)) && SGJK_EXPECT_F(([keyObject   isKindOfClass:[NSString class]] == NO))) { SGJK_encode_error(encodeState, @"Key must be a string object."); return(1); }
            if(SGJK_EXPECT_F(SGJK_encode_add_atom_to_buffer(encodeState, keyObject)))                                                        { return(1); }
            if(SGJK_EXPECT_F(SGJK_encode_write1(encodeState, 0L, ":")))                                                                      { return(1); }
            if(SGJK_EXPECT_F(SGJK_encode_add_atom_to_buffer(encodeState, (void *)CFDictionaryGetValue((CFDictionaryRef)object, keyObject)))) { return(1); }
          }
        } else {
          void *keys[1024], *objects[1024];
          CFDictionaryGetKeysAndValues((CFDictionaryRef)object, (const void **)keys, (const void **)objects);
          for(idx = 0L; idx < dictionaryCount; idx++) {
            if(SGJK_EXPECT_T(printComma)) { if(SGJK_EXPECT_F(SGJK_encode_write1(encodeState, 0L, ","))) { return(1); } }
            printComma = 1;
            if(SGJK_EXPECT_F(((id)keys[idx])->isa != encodeState->fastClassLookup.stringClass) && SGJK_EXPECT_F([(id)keys[idx] isKindOfClass:[NSString class]] == NO)) { SGJK_encode_error(encodeState, @"Key must be a string object."); return(1); }
            if(SGJK_EXPECT_F(SGJK_encode_add_atom_to_buffer(encodeState, keys[idx])))    { return(1); }
            if(SGJK_EXPECT_F(SGJK_encode_write1(encodeState, 0L, ":")))                  { return(1); }
            if(SGJK_EXPECT_F(SGJK_encode_add_atom_to_buffer(encodeState, objects[idx]))) { return(1); }
          }
        }
        return(SGJK_encode_write1(encodeState, -1L, "}"));
      }
      break;

    case SGJKClassNull: return(SGJK_encode_writen(encodeState, cacheSlot, startingAtIndex, encodeCacheObject, "null", 4UL)); break;

    default: SGJK_encode_error(encodeState, @"Unable to serialize object class %@.", NSStringFromClass([object class])); return(1); break;
  }

  return(0);
}


@implementation SGJKSerializer

+ (id)serializeObject:(id)object options:(SGJKSerializeOptionFlags)optionFlags encodeOption:(SGJKEncodeOptionType)encodeOption block:(SGJKSERIALIZER_BLOCKS_PROTO)block delegate:(id)delegate selector:(SEL)selector error:(NSError **)error
{
  return([[[[self alloc] init] autorelease] serializeObject:object options:optionFlags encodeOption:encodeOption block:block delegate:delegate selector:selector error:error]);
}

- (id)serializeObject:(id)object options:(SGJKSerializeOptionFlags)optionFlags encodeOption:(SGJKEncodeOptionType)encodeOption block:(SGJKSERIALIZER_BLOCKS_PROTO)block delegate:(id)delegate selector:(SEL)selector error:(NSError **)error
{
#ifndef __BLOCKS__
#pragma unused(block)
#endif
  NSParameterAssert((object != NULL) && (encodeState == NULL) && ((delegate != NULL) ? (block == NULL) : 1) && ((block != NULL) ? (delegate == NULL) : 1) &&
                    (((encodeOption & SGJKEncodeOptionCollectionObj) != 0UL) ? (((encodeOption & SGJKEncodeOptionStringObj)     == 0UL) && ((encodeOption & SGJKEncodeOptionStringObjTrimQuotes) == 0UL)) : 1) &&
                    (((encodeOption & SGJKEncodeOptionStringObj)     != 0UL) ?  ((encodeOption & SGJKEncodeOptionCollectionObj) == 0UL)                                                                 : 1));

  id returnObject = NULL;

  if(encodeState != NULL) { [self releaseState]; }
  if((encodeState = (struct SGJKEncodeState *)calloc(1UL, sizeof(SGJKEncodeState))) == NULL) { [NSException raise:NSMallocException format:@"Unable to allocate state structure."]; return(NULL); }

  if((error != NULL) && (*error != NULL)) { *error = NULL; }

  if(delegate != NULL) {
    if(selector                               == NULL) { [NSException raise:NSInvalidArgumentException format:@"The delegate argument is not NULL, but the selector argument is NULL."]; }
    if([delegate respondsToSelector:selector] == NO)   { [NSException raise:NSInvalidArgumentException format:@"The serializeUnsupportedClassesUsingDelegate: delegate does not respond to the selector argument."]; }
    encodeState->classFormatterDelegate = delegate;
    encodeState->classFormatterSelector = selector;
    encodeState->classFormatterIMP      = (SGJKClassFormatterIMP)[delegate methodForSelector:selector];
    NSCParameterAssert(encodeState->classFormatterIMP != NULL);
  }

#ifdef __BLOCKS__
  encodeState->classFormatterBlock                          = block;
#endif
  encodeState->serializeOptionFlags                         = optionFlags;
  encodeState->encodeOption                                 = encodeOption;
  encodeState->stringBuffer.roundSizeUpToMultipleOf         = (1024UL * 32UL);
  encodeState->utf8ConversionBuffer.roundSizeUpToMultipleOf = 4096UL;
    
  unsigned char stackJSONBuffer[SGJK_JSONBUFFER_SIZE] SGJK_ALIGNED(64);
  SGJK_managedBuffer_setToStackBuffer(&encodeState->stringBuffer,         stackJSONBuffer, sizeof(stackJSONBuffer));

  unsigned char stackUTF8Buffer[SGJK_UTF8BUFFER_SIZE] SGJK_ALIGNED(64);
  SGJK_managedBuffer_setToStackBuffer(&encodeState->utf8ConversionBuffer, stackUTF8Buffer, sizeof(stackUTF8Buffer));

  if(((encodeOption & SGJKEncodeOptionCollectionObj) != 0UL) && (([object isKindOfClass:[NSArray  class]] == NO) && ([object isKindOfClass:[NSDictionary class]] == NO))) { SGJK_encode_error(encodeState, @"Unable to serialize object class %@, expected a NSArray or NSDictionary.", NSStringFromClass([object class])); goto errorExit; }
  if(((encodeOption & SGJKEncodeOptionStringObj)     != 0UL) &&  ([object isKindOfClass:[NSString class]] == NO))                                                         { SGJK_encode_error(encodeState, @"Unable to serialize object class %@, expected a NSString.", NSStringFromClass([object class])); goto errorExit; }

  if(SGJK_encode_add_atom_to_buffer(encodeState, object) == 0) {
    BOOL stackBuffer = ((encodeState->stringBuffer.flags & SGJKManagedBufferMustFree) == 0UL) ? YES : NO;
    
    if((encodeState->atIndex < 2UL))
    if((stackBuffer == NO) && ((encodeState->stringBuffer.bytes.ptr = (unsigned char *)reallocf(encodeState->stringBuffer.bytes.ptr, encodeState->atIndex + 16UL)) == NULL)) { SGJK_encode_error(encodeState, @"Unable to realloc buffer"); goto errorExit; }

    switch((encodeOption & SGJKEncodeOptionAsTypeMask)) {
      case SGJKEncodeOptionAsData:
        if(stackBuffer == YES) { if((returnObject = [(id)CFDataCreate(                 NULL,                encodeState->stringBuffer.bytes.ptr, (CFIndex)encodeState->atIndex)                                  autorelease]) == NULL) { SGJK_encode_error(encodeState, @"Unable to create NSData object"); } }
        else                   { if((returnObject = [(id)CFDataCreateWithBytesNoCopy(  NULL,                encodeState->stringBuffer.bytes.ptr, (CFIndex)encodeState->atIndex, NULL)                            autorelease]) == NULL) { SGJK_encode_error(encodeState, @"Unable to create NSData object"); } }
        break;

      case SGJKEncodeOptionAsString:
        if(stackBuffer == YES) { if((returnObject = [(id)CFStringCreateWithBytes(      NULL, (const UInt8 *)encodeState->stringBuffer.bytes.ptr, (CFIndex)encodeState->atIndex, kCFStringEncodingUTF8, NO)       autorelease]) == NULL) { SGJK_encode_error(encodeState, @"Unable to create NSString object"); } }
        else                   { if((returnObject = [(id)CFStringCreateWithBytesNoCopy(NULL, (const UInt8 *)encodeState->stringBuffer.bytes.ptr, (CFIndex)encodeState->atIndex, kCFStringEncodingUTF8, NO, NULL) autorelease]) == NULL) { SGJK_encode_error(encodeState, @"Unable to create NSString object"); } }
        break;

      default: SGJK_encode_error(encodeState, @"Unknown encode as type."); break;
    }

    if((returnObject != NULL) && (stackBuffer == NO)) { encodeState->stringBuffer.flags &= ~SGJKManagedBufferMustFree; encodeState->stringBuffer.bytes.ptr = NULL; encodeState->stringBuffer.bytes.length = 0UL; }
  }

errorExit:
  if((encodeState != NULL) && (error != NULL) && (encodeState->error != NULL)) { *error = encodeState->error; encodeState->error = NULL; }
  [self releaseState];

  return(returnObject);
}

- (void)releaseState
{
  if(encodeState != NULL) {
    SGJK_managedBuffer_release(&encodeState->stringBuffer);
    SGJK_managedBuffer_release(&encodeState->utf8ConversionBuffer);
    free(encodeState); encodeState = NULL;
  }  
}

- (void)dealloc
{
  [self releaseState];
  [super dealloc];
}

@end

@implementation NSString (SGJSONKitSerializing)

////////////
#pragma mark Methods for serializing a single NSString.
////////////

// Useful for those who need to serialize just a NSString.  Otherwise you would have to do something like [NSArray arrayWithObject:stringToBeJSONSerialized], serializing the array, and then chopping of the extra ^\[.*\]$ square brackets.

// NSData returning methods...

- (NSData *)JSONData
{
  return([self JSONDataWithOptions:SGJKSerializeOptionNone includeQuotes:YES error:NULL]);
}

- (NSData *)JSONDataWithOptions:(SGJKSerializeOptionFlags)serializeOptions includeQuotes:(BOOL)includeQuotes error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsData | ((includeQuotes == NO) ? SGJKEncodeOptionStringObjTrimQuotes : 0UL) | SGJKEncodeOptionStringObj) block:NULL delegate:NULL selector:NULL error:error]);
}

// NSString returning methods...

- (NSString *)JSONString
{
  return([self JSONStringWithOptions:SGJKSerializeOptionNone includeQuotes:YES error:NULL]);
}

- (NSString *)JSONStringWithOptions:(SGJKSerializeOptionFlags)serializeOptions includeQuotes:(BOOL)includeQuotes error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsString | ((includeQuotes == NO) ? SGJKEncodeOptionStringObjTrimQuotes : 0UL) | SGJKEncodeOptionStringObj) block:NULL delegate:NULL selector:NULL error:error]);
}

@end

@implementation NSArray (SGJSONKitSerializing)

// NSData returning methods...

- (NSData *)JSONData
{
  return([SGJKSerializer serializeObject:self options:SGJKSerializeOptionNone encodeOption:(SGJKEncodeOptionAsData | SGJKEncodeOptionCollectionObj) block:NULL delegate:NULL selector:NULL error:NULL]);
}

- (NSData *)JSONDataWithOptions:(SGJKSerializeOptionFlags)serializeOptions error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsData | SGJKEncodeOptionCollectionObj) block:NULL delegate:NULL selector:NULL error:error]);
}

- (NSData *)JSONDataWithOptions:(SGJKSerializeOptionFlags)serializeOptions serializeUnsupportedClassesUsingDelegate:(id)delegate selector:(SEL)selector error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsData | SGJKEncodeOptionCollectionObj) block:NULL delegate:delegate selector:selector error:error]);
}

// NSString returning methods...

- (NSString *)JSONString
{
  return([SGJKSerializer serializeObject:self options:SGJKSerializeOptionNone encodeOption:(SGJKEncodeOptionAsString | SGJKEncodeOptionCollectionObj) block:NULL delegate:NULL selector:NULL error:NULL]);
}

- (NSString *)JSONStringWithOptions:(SGJKSerializeOptionFlags)serializeOptions error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsString | SGJKEncodeOptionCollectionObj) block:NULL delegate:NULL selector:NULL error:error]);
}

- (NSString *)JSONStringWithOptions:(SGJKSerializeOptionFlags)serializeOptions serializeUnsupportedClassesUsingDelegate:(id)delegate selector:(SEL)selector error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsString | SGJKEncodeOptionCollectionObj) block:NULL delegate:delegate selector:selector error:error]);
}

@end

@implementation NSDictionary (SGJSONKitSerializing)

// NSData returning methods...

- (NSData *)JSONData
{
  return([SGJKSerializer serializeObject:self options:SGJKSerializeOptionNone encodeOption:(SGJKEncodeOptionAsData | SGJKEncodeOptionCollectionObj) block:NULL delegate:NULL selector:NULL error:NULL]);
}

- (NSData *)JSONDataWithOptions:(SGJKSerializeOptionFlags)serializeOptions error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsData | SGJKEncodeOptionCollectionObj) block:NULL delegate:NULL selector:NULL error:error]);
}

- (NSData *)JSONDataWithOptions:(SGJKSerializeOptionFlags)serializeOptions serializeUnsupportedClassesUsingDelegate:(id)delegate selector:(SEL)selector error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsData | SGJKEncodeOptionCollectionObj) block:NULL delegate:delegate selector:selector error:error]);
}

// NSString returning methods...

- (NSString *)JSONString
{
  return([SGJKSerializer serializeObject:self options:SGJKSerializeOptionNone encodeOption:(SGJKEncodeOptionAsString | SGJKEncodeOptionCollectionObj) block:NULL delegate:NULL selector:NULL error:NULL]);
}

- (NSString *)JSONStringWithOptions:(SGJKSerializeOptionFlags)serializeOptions error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsString | SGJKEncodeOptionCollectionObj) block:NULL delegate:NULL selector:NULL error:error]);
}

- (NSString *)JSONStringWithOptions:(SGJKSerializeOptionFlags)serializeOptions serializeUnsupportedClassesUsingDelegate:(id)delegate selector:(SEL)selector error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsString | SGJKEncodeOptionCollectionObj) block:NULL delegate:delegate selector:selector error:error]);
}

@end


#ifdef __BLOCKS__

@implementation NSArray (SGJSONKitSerializingBlockAdditions)

- (NSData *)JSONDataWithOptions:(SGJKSerializeOptionFlags)serializeOptions serializeUnsupportedClassesUsingBlock:(id(^)(id object))block error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsData | SGJKEncodeOptionCollectionObj) block:block delegate:NULL selector:NULL error:error]);
}

- (NSString *)JSONStringWithOptions:(SGJKSerializeOptionFlags)serializeOptions serializeUnsupportedClassesUsingBlock:(id(^)(id object))block error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsString | SGJKEncodeOptionCollectionObj) block:block delegate:NULL selector:NULL error:error]);
}

@end

@implementation NSDictionary (SGJSONKitSerializingBlockAdditions)

- (NSData *)JSONDataWithOptions:(SGJKSerializeOptionFlags)serializeOptions serializeUnsupportedClassesUsingBlock:(id(^)(id object))block error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsData | SGJKEncodeOptionCollectionObj) block:block delegate:NULL selector:NULL error:error]);
}

- (NSString *)JSONStringWithOptions:(SGJKSerializeOptionFlags)serializeOptions serializeUnsupportedClassesUsingBlock:(id(^)(id object))block error:(NSError **)error
{
  return([SGJKSerializer serializeObject:self options:serializeOptions encodeOption:(SGJKEncodeOptionAsString | SGJKEncodeOptionCollectionObj) block:block delegate:NULL selector:NULL error:error]);
}

@end

#endif // __BLOCKS__

