/**
	Originally written by Josh Simmons in C.
*/

module irc.ringbuffer;

import std.c.stdlib;
import std.c.string;

/**
 * @file ring-buffer.h
 */

/// Fixed size continuous FIFO buffer.
struct RingBuffer
{
    /**
     * Pointer to data.
     */
    char *data;

    /**
     * Length of data.
     */
    size_t size;

    /**
     * Offset in data for finding the start of valid data.
     */
    size_t head;

    /**
     * Length of valid data.
     */
    size_t fill;
}

/// Create a new ring buffer.
/**
 * @param size Length of buffer in bytes.
 * @return Pointer to a newly allocated RingBuffer.
 * @sa rb_free
 */
RingBuffer *rb_new(size_t size)
{
    RingBuffer *buf = cast(RingBuffer*)malloc(RingBuffer.sizeof);
    assert(buf != null);

    buf.data = cast(char*)malloc(size);
    assert(buf.data != null);

    buf.size = size;
    buf.head = buf.fill = 0;

    return buf;
}

private void advance_tail(RingBuffer *buf, size_t bytes)
{
    buf.fill += bytes;
}

/// Check if buffer is empty.
/**
 * @param buf Buffer.
 * @return True if buffer is empty otherwise false.
 */
bool rb_is_empty(const RingBuffer *buf)
{
    return buf.fill == 0;
}

/// Check if buffer is full.
/**
 * @param buf Buffer.
 * @return True if buffer is full.
 */
bool rb_is_full(const RingBuffer *buf)
{
    return buf.fill == buf.size;
}

/// Get the length of the buffer.
/**
 * @param buf Buffer.
 * @return Size of buffer in bytes.
 */
size_t rb_size(const RingBuffer *buf)
{
    return buf.size;
}

/// Get the length of valid data.
/**
 * @param buf Buffer.
 * @return Length of valid data in bytes.
 */
size_t rb_used(const RingBuffer *buf)
{
    return buf.fill;
}

/// Get the free space remaining.
/**
 * @param buf Buffer.
 * @return Length of free space in bytes.
 */
size_t rb_remain(const RingBuffer *buf)
{
    return buf.size - buf.fill;
}

/// Empty the buffer of valid data.
/**
 * @param buf Buffer.
 */
void rb_empty(RingBuffer *buf)
{
    buf.head = buf.fill = 0;
}

/// Copy data into buffer.
/**
 * @remark This will extend the valid section so calling rb_write_commit() manually is
 * unnecessary.
 *
 * @param buf Target.
 * @param from Pointer to data.
 * @param bytes Length of data to copy in bytes.
 */
void rb_write(RingBuffer *buf, const char *from, size_t bytes)
{
    assert(bytes <= rb_remain(buf));

    char *tail = buf.data + ((buf.head + buf.fill) % buf.size);
    char *write_end = buf.data + ((buf.head + buf.fill + bytes) % buf.size);

    if(tail <= write_end)
    {
        memcpy(tail, from, bytes);
    }
    else
    {
        char *end = buf.data + buf.size;
        
        size_t first_write = end - tail;
        memcpy(tail, from, first_write);
        
        size_t second_write = bytes - first_write;
        memcpy(buf.data, from + first_write, second_write);
    }

    advance_tail(buf, bytes);
}

/// Get a pointer to directly writable space.
/**
 * @remark The number of bytes given by writable may be less than the total number remaining
 * free in the buffer, but the rest will be writable from a second call to this function
 * that will return a different pointer. This is because of the 'wrap around' from the end
 * to the beginning of the buffer's memory block.
 *
 * @param buf Buffer.
 * @param[out] writable Length of writable area in bytes.
 * @return Pointer to writable data.
 * @sa rb_write_commit
 */
char *rb_write_pointer(RingBuffer *buf, size_t *writable)
{
    if(rb_is_full(buf))
    {
        *writable = 0;
        return null;
    }

    char* head = buf.data + buf.head;
    char* tail = buf.data + ((buf.head + buf.fill) % buf.size);

    if(tail < head)
    {
        *writable = head - tail;
    }
    else
    {
        char* end = buf.data + buf.size;
        *writable = end - tail;
    }

    return tail;
}

/// Extend the valid section after a write operation.
/**
 * @remark If this is not called following a write the data written is essentially discarded.
 *
 * @param buf Buffer.
 * @param bytes Length by which to extend the valid section.
 * @sa rb_write_pointer
 */
void rb_write_commit(RingBuffer *buf, size_t bytes)
{
    assert(bytes <= rb_remain(buf));
    advance_tail(buf, bytes);
}

private void advance_head(RingBuffer *buf, size_t bytes)
{
    buf.head = (buf.head + bytes) % buf.size;
    buf.fill -= bytes;
}

/// Copy data from a buffer.
/**
 * @remark This advances the buffer as well as copying the data so calling rb_read_commit() is
 * unnecessary.
 *
 * @param buf Buffer.
 * @param to Target of copy.
 * @param bytes Number of bytes to copy.
 * @sa rb_read_pointer
 */
void rb_read(RingBuffer *buf, char *to, size_t bytes)
{
    assert(bytes <= rb_used(buf));

    char *head = buf.data + buf.head;
    char *end_read = buf.data + ((buf.head + bytes) % buf.size);

    if(end_read <= head)
    {
        char *end = buf.data + buf.size;

        size_t first_read = end - head;
        memcpy(to, head, first_read);

        size_t second_read = bytes - first_read;
        memcpy(to + first_read, buf.data, second_read);
    }
    else
    {
        memcpy(to, head, bytes);
    }

    advance_head(buf, bytes); 
}

/// Get a pointer to directly readable space in buffer.
/**
 * @remark The number of bytes given by readable may be less than the total number used by
 * the buffer, but the rest will be writable from a second call to this function
 * that will return a different pointer. This is because of the 'wrap around' from 
 * the end to the beginning of the buffer's memory block.
 *
 * @param buf Buffer.
 * @param offset Offset into valid data from which to read.
 * @param[out] readable Length of readable data in bytes.
 * @return Pointer to readable data.
 * @sa rb_read_commit
 */
const(char)* rb_read_pointer(RingBuffer *buf, size_t offset, size_t *readable)
{
    if(rb_is_empty(buf))
    {
        *readable = 0;
        return null;
    }

    char *head = buf.data + buf.head + offset;
    char *tail = buf.data + ((buf.head + offset + buf.fill) % buf.size);

    if(tail <= head)
    {
        char *end = buf.data + buf.size;
        *readable = end - head;
    }
    else
    {
        *readable = tail - head;
    }

    return head;
}

/// Advance head of valid data.
/**
 * This updates the buffer's state moving the head of the valid data forwards such
 * that data at the beginning of the valid section is discarded.
 *
 * @remark This can be called following rb_read_pointer(), or not. The lifetime of
 * specific data in the buffer is up to the user.
 * 
 * @param buf Buffer.
 * @param bytes Amount to advance head by in bytes.
 */
void rb_read_commit(RingBuffer *buf, size_t bytes)
{
    assert(rb_used(buf) >= bytes);
    advance_head(buf, bytes);
}

/// Stream the contents of one buffer into another.
/**
 * @param from Buffer to copy from.
 * @param to Buffer to copy to.
 * @param bytes Number of bytes to copy.
 */
void rb_stream(RingBuffer *from, RingBuffer *to, size_t bytes)
{
    assert(rb_used(from) <= bytes);
    assert(rb_remain(to) >= bytes);

    size_t copied = 0;
    while(copied < bytes)
    {
        size_t can_read;
        const char *from_ptr = rb_read_pointer(from, copied, &can_read);

        size_t copied_this_read = 0;
        
        while(copied_this_read < can_read)
        {
            size_t can_write;
            char *to_ptr = rb_write_pointer(to, &can_write);

            size_t write = (can_read > can_write) ? can_write : can_read;
            memcpy(to_ptr, from_ptr, write);

            copied_this_read += write;
        }

        copied += copied_this_read;
    }

    advance_tail(to, copied);
}

/// Free a RingBuffer object allocated by rb_new() and the data backing it.
/**
 * @remark Can be called safely on a NULL pointer.
 * @param buf Buffer.
 * @sa rb_new
 */
void rb_free(RingBuffer *buf)
{
    if(buf != null)
    {
        free(buf.data);
        free(buf);
    }
}
