# malloc / libmem

This library (`libmem.p8`) provides most of the C style malloc routines for Prog8.
With `libmem` you can dynamically allocate and free memory blocks from a pool.

Some additional convenience routines may be added in the future. For example a
size routine that returns the allocated size of a pointer might be useful.

Another useful routine could calculate how much memory is free.  Or maybe return
the size of the largest free block.  Feedback is welcome.

## Demo

In `src/main.p8` and `src/tests.p8` is a demonstration program that executes a number
tests with validation of the results.  It is meant as a bit of a torture test
of the routines.  You can run it on C64 or CX16 with `make emu-c64` or `make emu-cx16`
if you have your Prog8 environment setup with VICE and x16emu.

One test does a number of random operations which can take 30+ seconds to complete.
Warp mode in VICE is helpful.  The X16's 8MHz clock rate helps a lot as well.

## Usage

The library has to be imported to make it available to your Prog8 routines.
Note the library file is called `libmem.p8` but the block is just `mem` right now.
This may change so the filename and block match in the future once the Prog8
community settles on a standard way to use 3rd party library modules.

```
%import libmem
```

### init
To use the library once it has been imported you must initialization it.
Generally this should be done immediately in your `start` subroutine.

There are currently two ways to initialize libmem right now.  The automatic
way is to just call `mem.init()` which will use the available memory from the
end of your Prog8 program (by calling `sys.progend()`) and the start of I/O
space.  That would be $9f00 on CX16 and $d000 on C64. On C64, 32 bytes are subtracted
for the CX16 style virtual registers.  So it is really $cfe0 not $d000.

The second initialization method is to manually specify the start and end
memory addresses. Note the *end* address should be in the typical CBM notation
where it is actually 1 byte past the last byte in the range.  So with the CX16
when specifying the end address prior to the I/O  space you would use `$9f00` not
`$9eff`. This makes it consistent with MEMTOP for example.

Below are examples of the automatic and manual initialization.  You should **only
use one** method:
```
mem.init()
mem.initm($8000, $9f00)
```

Once libmem has been initialized you can use the standard functions.

### calloc
Alphabetically we start with `calloc` which takes the parameters shown below
and returns a uword pointer or `mem.NULL` (defined as $0000 right now). It also uses
`sys.memset` to clear the allocation to zeroes.

`sub calloc(uword elements, uword size) -> uword`

The elements parameter is a quantity of the size parameter units.  These two numbers
are multiplied together to get the amount of requested memory.  If the allocation
failures it will return `mem.NULL`.

An example of allocating 20 elements of 100 bytes each would look like:
```
uword ptr = mem.calloc(20, 100)
```

### free
The `free` routine takes a pointer to a memory block and frees it.  It also attempts
to combine adjacent free blocks into a larger block.  The routine checks for NULL
pointers and doesn't attempt to free them.  You *MUST NOT* attempt to free the
same pointer twice.

Free takes a pointer argument and returns nothing.  The pointer is no longer valid
after calling free with it.  Best practice is to set a freed pointer to `mem.NULL`
immediately after freeing it to avoid attempting a double free.

Example:
```
uword ptr = mem.calloc(20, 100)
...
mem.free(ptr)
ptr = mem.NULL
```

### malloc

The most used routine in libmem is likely to be `malloc` which allocates a block
of ram of a certain size, if available, and returns a pointer. If there isn't ram
available to service the request then `mem.NULL` is returned. The `malloc` routine
will look through the mempool for a free block that is greater than or equal to the
requested size. A larger block will be resized to the requested size and returned.

The malloc routine takes a uword size argument.
`sub malloc(uword size) -> uword`

Example usage:
```
uword ptr = mem.malloc(4096)
```

### realloc

Calling `realloc` will change the size of an existing allocation.  If you call it
with a size that is smaller than the current block, the block will be truncated
to the requested size.  If you request a size larger than the current size, then
the mempool will be searched for a block greater than or equal to the requested size.
If a block is found, it will be resized to the request size like with `malloc` and
then the data from the current block will be copied to the new block and the current
block / pointer will be freed.

If there is not enough ram available then `realloc` will return `mem.NULL` to the caller.
NOTE: *the original pointer will still be valid if realloc() returns NULL*

`sub realloc(uword ptr, uword size) -> uword`

Here is a usage example:
```
uword ptr = mem.malloc(100)
uword temp = mem.realloc(ptr, 1000)
if temp != mem.NULL
    ptr = temp
```

