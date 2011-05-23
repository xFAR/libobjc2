/*
 * Copyright (c) 2009 Remy Demarest
 * Portions Copyright (c) 2009 David Chisnall
 *  
 *  Permission is hereby granted, free of charge, to any person
 *  obtaining a copy of this software and associated documentation
 *  files (the "Software"), to deal in the Software without
 *  restriction, including without limitation the rights to use,
 *  copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the
 *  Software is furnished to do so, subject to the following
 *  conditions:
 *   
 *  The above copyright notice and this permission notice shall be
 *  included in all copies or substantial portions of the Software.
 *   
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 *  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 *  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 *  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 *  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 *  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 *  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 *  OTHER DEALINGS IN THE SOFTWARE.
 */
#import "objc/blocks_runtime.h"
#import "objc/runtime.h"
#include "gc_ops.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <assert.h>

#define fprintf(...)

/* Makes the compiler happy even without Foundation */
@interface Dummy
- (id)retain;
- (void)release;
@end

static void *_HeapBlockByRef = (void*)1;

/**
 * Block descriptor flags.  
 */
enum block_flags
{
	/**
	 * The block descriptor contains copy and dispose helpers.
	 */
	BLOCK_HAS_COPY_DISPOSE = (1 << 25),
	/**
	 * The helpers have C++ code.
	 */
	BLOCK_HAS_CTOR         = (1 << 26),
	/**
	 * Block is stored in global memory and does not need to be copied.
	 */
	BLOCK_IS_GLOBAL        = (1 << 28),
	/**
	 * Block function uses a calling convention that returns a structure via a
	 * pointer passed in by the caller.
	 */
	BLOCK_USE_SRET         = (1 << 29),
	/**
	 * Block has an Objective-C type encoding.
	 */
	BLOCK_HAS_SIGNATURE    = (1 << 30),
	/**
	 * Mask for the reference count in byref structure's flags field.  The low
	 * 3 bytes are reserved for the reference count, the top byte for the
	 * flags.
	 */
	BLOCK_REFCOUNT_MASK    = 0x00ffffff
};

/**
 * Flags used in the final argument to _Block_object_assign() and
 * _Block_object_dispose().  These indicate the type of copy or dispose to
 * perform.
 */
enum 
{
	/**
	 * The value is of some id-like type, and should be copied as an
	 * Objective-C object: i.e. by sending -retain or via the GC assign
	 * functions in GC mode (not yet supported).
	 */
	BLOCK_FIELD_IS_OBJECT   =  3,
	/**
	 * The field is a block.  This must be copied by the block copy functions.
	 */
	BLOCK_FIELD_IS_BLOCK	=  7,
	/**
	 * The field is an indirect reference to a variable declared with the
	 * __block storage qualifier.
	 */
	BLOCK_FIELD_IS_BYREF	=  8,  // the on stack structure holding the __block variable
	
	BLOCK_FIELD_IS_WEAK	 = 16,  // declared __weak
	
	BLOCK_BYREF_CALLER	  = 128, // called from byref copy/dispose helpers
};
#define IS_SET(x, y) ((x & y) == y)

/**
 * Block descriptor that contains copy and dispose operations.
 */
struct block_descriptor_copydispose
{
	/**
	 * Reserved for future use.  Currently always 0.
	 */
	unsigned long int reserved;
	/** Size of the block. */
	unsigned long int size;
	/**
	 * Copy function, generated by the compiler to help copy the block if it
	 * contains nontrivial copy operations.
	 */
	void (*copy_helper)(void *dst, void *src);
	/**
	 * Dispose function, generated by the compiler to help copy the block if it
	 * contains nontrivial destructors.
	 */
	void (*dispose_helper)(void *src); 
	/**
	 * Objective-C type encoding of the block.
	 */
	const char *encoding;
};
/**
 * Block descriptor that does not contain copy and dispose helper functions.
 */
struct block_descriptor
{
	/**
	 * Reserved for future use, currently always 0.
	 */
	unsigned long int reserved;
	/** Size of the block. */
	unsigned long int size;
	/**
	 * Objective-C type encoding of the block.
	 */
	const char *encoding;
};

// Helper structure
struct block_literal
{
	/**
	 * Class pointer.  Always initialised to &_NSConcreteStackBlock for blocks
	 * that are created on the stack or &_NSConcreteGlobalBlock for blocks that
	 * are created in global storage.
	 */
	void *isa;
	/**
	 * Flags.  See the block_flags enumerated type for possible values.
	 */
	int flags;
	/**
	 * Reserved - always initialised to 0 by the compiler.  Used for the
	 * reference count in this implementation.
	 */
	int reserved;
	/**
	 * The function that implements the block.  The first argument is this
	 * structure, the subsequent arguments are the block's explicit parameters.
	 * If the BLOCK_USE_SRET flag is set, there is an additional hidden
	 * argument, which is a pointer to the space on the stack allocated to hold
	 * the return value.
	 */
	void (*invoke)(void *, ...);
	/**
	 * The block's descriptor.  This is either block_descriptor or
	 * block_descriptor_copydispose, depending on whether the
	 * BLOCK_HAS_COPY_DISPOSE flag is set.
	 */
	struct block_descriptor_copydispose *descriptor;
	/**
	 * Block variables are appended to this structure.
	 */
};

/**
 * Structure used for on-stack variables that are referenced by blocks.
 */
struct block_byref_obj
{
	/**
	 * Class pointer.  Currently unused and always NULL.  Could be used in the
	 * future to support introspection.
	 */
	void *isa;
	/**
	 * The pointer to the structure that contains the real version of the data.
	 * All accesses go via this pointer.  If an on-stack byref structure is
	 * copied to the heap, then its forwarding pointer should point to the heap
	 * version.  Otherwise it should point to itself.
	 */
	struct block_byref_obj *forwarding;
	/**
	 * Flags and reference count.
	 */
	int flags;   //refcount;
	/**
	 * Size of this structure.
	 */
	int size;
	/**
	 * Copy function.
	 */
	void (*byref_keep)(struct block_byref_obj *dst, const struct block_byref_obj *src);
	/**
	 * Dispose function.
	 */
	void (*byref_dispose)(struct block_byref_obj *);
	/**
	 * __block-qualified variables are copied here.
	 */
};


/**
 * Returns the Objective-C type encoding for the block.
 */
const char *block_getType_np(void *b)
{
	struct block_literal *block = b;
	if ((NULL == block) || !(block->flags & BLOCK_HAS_SIGNATURE))
	{
		return NULL;
	}
	if (!(block->flags & BLOCK_HAS_COPY_DISPOSE))
	{
		return ((struct block_descriptor*)block->descriptor)->encoding;
	}
	return block->descriptor->encoding;
}

static int increment24(int *ref)
{
	int old = *ref;
	int val = old & BLOCK_REFCOUNT_MASK;
	// FIXME: We should gracefully handle refcount overflow, but for now we
	// just give up
	assert(val < BLOCK_REFCOUNT_MASK);
	if (!__sync_bool_compare_and_swap(ref, old, old+1))
	{
		return increment24(ref);
	}
	return val + 1;
}

static int decrement24(int *ref)
{
	int old = *ref;
	int val = old & BLOCK_REFCOUNT_MASK;
	// FIXME: We should gracefully handle refcount overflow, but for now we
	// just give up
	assert(val > 0);
	if (!__sync_bool_compare_and_swap(ref, old, old-1))
	{
		return decrement24(ref);
	}
	return val - 1;
}

// This is a really ugly hack that works around a buggy register allocator in
// GCC.  Compiling nontrivial code using __sync_bool_compare_and_swap() with
// GCC (4.2.1, at least), causes the register allocator to run out of registers
// and fall over and die.  We work around this by wrapping this CAS in a
// function, which means the register allocator can trivially handle it.  Do
// not remove the noinline attribute - without it, gcc will inline it early on
// and then crash later.
#ifndef __clang__
__attribute__((noinline))
static int cas(void *ptr, void *old, void *new)
{
	return __sync_bool_compare_and_swap((void**)ptr, old, new);
}
#define __sync_bool_compare_and_swap cas
#endif

/* Certain field types require runtime assistance when being copied to the
 * heap.  The following function is used to copy fields of types: blocks,
 * pointers to byref structures, and objects (including
 * __attribute__((NSObject)) pointers.  BLOCK_FIELD_IS_WEAK is orthogonal to
 * the other choices which are mutually exclusive.  Only in a Block copy helper
 * will one see BLOCK_FIELD_IS_BYREF.
 */
void _Block_object_assign(void *destAddr, const void *object, const int flags)
{
	fprintf(stderr, "assign: %d\n", flags);
	//printf("Copying %x to %x with flags %x\n", object, destAddr, flags);
	// FIXME: Needs to be implemented
	//if(flags & BLOCK_FIELD_IS_WEAK)
	{
	}
	//else
	{
		fprintf(stderr, "BLOCK_FIELD_IS_OBJECT: %d\n", (flags & BLOCK_FIELD_IS_OBJECT) == BLOCK_FIELD_IS_OBJECT);
		fprintf(stderr, "BLOCK_FIELD_IS_BLOCK: %d\n", (flags & BLOCK_FIELD_IS_BLOCK) == BLOCK_FIELD_IS_BLOCK);
		fprintf(stderr, "BLOCK_FIELD_IS_BYREF: %d\n", (flags & BLOCK_FIELD_IS_BYREF) == BLOCK_FIELD_IS_BYREF);
		fprintf(stderr, "BLOCK_FIELD_IS_WEAK: %d\n", (flags & BLOCK_FIELD_IS_WEAK) == BLOCK_FIELD_IS_WEAK);
		if(flags & BLOCK_FIELD_IS_BYREF)
		{
			struct block_byref_obj *src = (struct block_byref_obj *)object;
			struct block_byref_obj **dst = destAddr;
			fprintf(stderr, "Copy dispose? %d\n", (src->flags & BLOCK_HAS_COPY_DISPOSE) == BLOCK_HAS_COPY_DISPOSE);
			fprintf(stderr, "Retain Count? %x %x\n", src->flags & BLOCK_REFCOUNT_MASK, BLOCK_REFCOUNT_MASK);
			
			if ((src->flags & BLOCK_REFCOUNT_MASK) == 0)
			{
				*dst = gc->malloc(src->size);
				fprintf(stderr, "Copying %d bytes to %p\n", src->size, *dst);
				memcpy(*dst, src, src->size);
				(*dst)->isa = _HeapBlockByRef;
				// Refcount must be two; one for the copy and one for the
				// on-stack version that will point to it.
				(*dst)->flags += 2;
				if ((size_t)src->size >= sizeof(struct block_byref_obj))
				{
					src->byref_keep(*dst, src);
				}
				(*dst)->forwarding = *dst;
				// Concurrency.  If we try copying the same byref structure
				// from two threads simultaneously, we could end up with two
				// versions on the heap that are unaware of each other.  That
				// would be bad.  So we first set up the copy, then try to do
				// an atomic compare-and-exchange to point the old version at
				// it.  If the forwarding pointer in src has changed, then we
				// recover - clean up and then return the structure that the
				// other thread created.
				if (!__sync_bool_compare_and_swap(&src->forwarding, src, *dst))
				{
					if((size_t)src->size >= sizeof(struct block_byref_obj))
					{
						src->byref_dispose(*dst);
					}
					gc->free(*dst);
					*dst = src->forwarding;
				}
			}
			else
			{
				*dst = (struct block_byref_obj*)src;
				increment24(&(*dst)->flags);
				fprintf(stderr, "Flags for block: %p: %d (refcount %x)\n", *dst, (*dst)->flags, (*dst)->flags & BLOCK_REFCOUNT_MASK);
			}
		}
		else if((flags & BLOCK_FIELD_IS_BLOCK) == BLOCK_FIELD_IS_BLOCK)
		{
			struct block_literal *src = (struct block_literal*)object;
			struct block_literal **dst = destAddr;
			
			*dst = Block_copy(src);
		}
		else if ((flags & BLOCK_FIELD_IS_OBJECT) == BLOCK_FIELD_IS_OBJECT)
		{
			fprintf(stderr, "-retain\n");
			id src = (id)object;
			id *dst = destAddr;
			*dst = [src retain];
		}
	}
}

/* Similarly a compiler generated dispose helper needs to call back for each
 * field of the byref data structure.  (Currently the implementation only packs
 * one field into the byref structure but in principle there could be more).
 * The same flags used in the copy helper should be used for each call
 * generated to this function:
 */
void _Block_object_dispose(const void *object, const int flags)
{
	fprintf(stderr, "Dispose %p, Flags: %d\n", object, flags);
		fprintf(stderr, "BLOCK_FIELD_IS_OBJECT: %d\n", (flags & BLOCK_FIELD_IS_OBJECT) == BLOCK_FIELD_IS_OBJECT);
		fprintf(stderr, "BLOCK_FIELD_IS_BLOCK: %d\n", (flags & BLOCK_FIELD_IS_BLOCK) == BLOCK_FIELD_IS_BLOCK);
		fprintf(stderr, "BLOCK_FIELD_IS_BYREF: %d\n", (flags & BLOCK_FIELD_IS_BYREF) == BLOCK_FIELD_IS_BYREF);
		fprintf(stderr, "BLOCK_FIELD_IS_WEAK: %d\n", (flags & BLOCK_FIELD_IS_WEAK) == BLOCK_FIELD_IS_WEAK);
	// FIXME: Needs to be implemented
	//if(flags & BLOCK_FIELD_IS_WEAK)
	{
	}
	//else
	{
		if(flags & BLOCK_FIELD_IS_BYREF)
		{
			struct block_byref_obj *src = 
				(struct block_byref_obj*)object;
			if (src->isa == _HeapBlockByRef)
			{
				fprintf(stderr, "refcount %x\n", src->flags & BLOCK_REFCOUNT_MASK);
				int refcount = (src->flags & BLOCK_REFCOUNT_MASK) == 0 ? 0 : decrement24(&src->flags);
				fprintf(stderr, "new refcount %x\n", refcount & BLOCK_REFCOUNT_MASK);
				if (refcount == 0)
				{
					if (0 != src->byref_dispose)
					{
						src->byref_dispose(src);
					}
					gc->free(src);
				}
			}
			else
			{
				fprintf(stderr, "src: %p\n", src);
				fprintf(stderr, "forwarding: %p\n", src->forwarding);
				fprintf(stderr, "dispose: %p\n", src->byref_dispose);
				fprintf(stderr, "Cleaning up %p\n" , *(id*)(src+1));
				// Call nontrivial destructors, but don't
				if (0 != src->byref_dispose)
				{
					//fprintf(stderr, "Calling byref dispose\n");
					src->byref_dispose(src);
					//fprintf(stderr, "Called byref dispose\n");
				}
				// If this block has been promoted to the heap, decrement its
				// reference count / destroy it if the heap version is already
				// dead.
				if (src->forwarding != src)
				{
					_Block_object_dispose(src->forwarding, flags | BLOCK_BYREF_CALLER);
				}
			}
		}
		else if ((flags & BLOCK_FIELD_IS_BLOCK) == BLOCK_FIELD_IS_BLOCK)
		{
			struct block_literal *src = (struct block_literal*)object;
			Block_release(src);
		}
		else if((flags & BLOCK_FIELD_IS_OBJECT) == BLOCK_FIELD_IS_OBJECT)
		{
			id src = (id)object;
			[src release];
		}
	}
}


// Copy a block to the heap if it's still on the stack or increments its retain count.
void *_Block_copy(void *src)
{
	fprintf(stderr, "_Block_copy()\n");
	struct block_literal *self = src;
	struct block_literal *ret = self;

	extern void _NSConcreteStackBlock;
	fprintf(stderr, "isa %p stack block %p\n", self->isa, &_NSConcreteStackBlock);
	
	// If the block is Global, there's no need to copy it on the heap.
	if(self->isa == &_NSConcreteStackBlock)
	{
		fprintf(stderr, "reserved: %d\n", self->reserved);
		fprintf(stderr, "block flags: %d\n", self->flags);
		if(self->reserved == 0)
		{
			ret = gc->malloc(self->descriptor->size);
			memcpy(ret, self, self->descriptor->size);
			if(self->flags & BLOCK_HAS_COPY_DISPOSE)
			{
	fprintf(stderr, "_Block_copy() calling copy helper\n");
				self->descriptor->copy_helper(ret, self);
			}
		}
		ret->reserved++;
	}
	return ret;
}

// Release a block and frees the memory when the retain count hits zero.
void _Block_release(void *src)
{
	struct block_literal *self = src;
	
	extern void _NSConcreteStackBlock;

	if(self->isa == &_NSConcreteStackBlock && // A Global block doesn't need to be released
	   self->reserved > 0)		// If false, then it's not allocated on the heap, we won't release auto memory !
	{
		self->reserved--;
		if(self->reserved == 0)
		{
			if(self->flags & BLOCK_HAS_COPY_DISPOSE)
				self->descriptor->dispose_helper(self);
			gc->free(self);
		}
	}
}
