/*******************************************************************************

        copyright:      Copyright (c) 2004 Kris Bell. All rights reserved

        license:        BSD style: $(LICENSE)

        version:        Mar 2004: Initial release
                        Dec 2006: Outback release

        authors:        Kris

*******************************************************************************/

module tango.io.stream.Buffer;

private import tango.io.device.Conduit;

/******************************************************************************

******************************************************************************/

public alias BufferInput  Bin;          /// shorthand alias
public alias BufferOutput Bout;         /// ditto

/******************************************************************************

******************************************************************************/

extern (C)
{
        private void * memcpy (void *dst, void *src, size_t);
}

/******************************************************************************

******************************************************************************/

private static char[] underflow = "input buffer is empty";
private static char[] eofRead   = "end-of-flow whilst reading";
private static char[] eofWrite  = "end-of-flow whilst writing";
private static char[] overflow  = "output buffer is full";


/*******************************************************************************

        Buffers the flow of data from a upstream input. A downstream 
        neighbour can locate and use this buffer instead of creating 
        another instance of their own. 

        (note that upstream is closer to the source, and downstream is
        further away)

*******************************************************************************/

class BufferInput : InputFilter, InputBuffer
{
        alias InputFilter.input input;

        private void[]        data;                   // the raw data buffer
        private size_t        index;                  // current read position
        private size_t        extent;                 // limit of valid content
        private size_t        dimension;              // maximum extent of content

        /***********************************************************************

                Ensure the buffer remains valid between method calls

        ***********************************************************************/

        invariant()
        {
                assert (index <= extent);
                assert (extent <= dimension);
        }

        /***********************************************************************

                Construct a buffer

                Params:
                stream = an input stream
                capacity = desired buffer capacity

                Remarks:
                Construct a Buffer upon the provided input stream.

        ***********************************************************************/

        this (InputStream stream)
        {
                this (stream, stream.conduit.bufferSize);
        }

        /***********************************************************************

                Construct a buffer

                Params:
                stream = an input stream
                capacity = desired buffer capacity

                Remarks:
                Construct a Buffer upon the provided input stream.

        ***********************************************************************/

        this (InputStream stream, size_t capacity)
        {
                set (new ubyte[capacity], 0);
                super (source = stream);
        }

        /***********************************************************************

                Attempt to share an upstream Buffer, and create an instance
                where there's not one available.

                Params:
                stream = an input stream

                Remarks:
                If an upstream Buffer instances is visible, it will be shared.
                Otherwise, a new instance is created based upon the bufferSize
                exposed by the stream endpoint (conduit).

        ***********************************************************************/

        static InputBuffer create (InputStream stream)
        {
                auto source = stream;
                auto conduit = source.conduit;
                while (cast(StreamMutator) source is null)
                      {
                      auto b = cast(InputBuffer) source;
                      if (b)
                          return b;
                      if (source is conduit)
                          break;
                      source = source.input;
                      assert (source);
                      }
                      
                return new BufferInput (stream, conduit.bufferSize);
        }

        /***********************************************************************
        
                Return a void[] slice of the buffer from start to end, where
                end is exclusive

        ***********************************************************************/

        final void[] opSlice (size_t start, size_t end)
        {
                assert (start <= extent && end <= extent && start <= end);
                return data [start .. end];
        }

        /***********************************************************************

                Retrieve the valid content

                Returns:
                a void[] slice of the buffer

                Remarks:
                Return a void[] slice of the buffer, from the current position
                up to the limit of valid content. The content remains in the
                buffer for future extraction.

        ***********************************************************************/

        final void[] slice ()
        {
                return  data [index .. extent];
        }

        /***********************************************************************

                Access buffer content

                Params:
                size =  number of bytes to access
                eat =   whether to consume the content or not

                Returns:
                the corresponding buffer slice when successful, or
                null if there's not enough data available (Eof; Eob).

                Remarks:
                Read a slice of data from the buffer, loading from the
                conduit as necessary. The specified number of bytes is
                sliced from the buffer, and marked as having been read
                when the 'eat' parameter is set true. When 'eat' is set
                false, the read position is not adjusted.

                Note that the slice cannot be larger than the size of
                the buffer ~ use method fill(void[]) instead where you
                simply want the content copied, or use conduit.read()
                to extract directly from an attached conduit. Also note
                that if you need to retain the slice, then it should be
                .dup'd before the buffer is compressed or repopulated.

                Examples:
                ---
                // create a buffer with some content
                auto buffer = new Buffer ("hello world");

                // consume everything unread
                auto slice = buffer.slice (buffer.readable);
                ---

        ***********************************************************************/

        final void[] slice (size_t size, bool eat = true)
        {
                if (size > readable)
                   {
                   // make some space? This will try to leave as much content
                   // in the buffer as possible, such that entire records may
                   // be aliased directly from within.
                   if (size > (dimension - index))
                       if (size > dimension)
                           conduit.error (underflow);

                   // populate tail of buffer with new content
                   do {
                      if (write (&source.read) is Eof)
                          conduit.error (eofRead);
                      } while (size > readable);
                   }

                auto i = index;
                if (eat)
                    index += size;
                return data [i .. i + size];
        }

        /***********************************************************************

                Read directly from this buffer

                Params:
                dg = callback to provide buffer access to

                Returns:
                Returns whatever the delegate returns.

                Remarks:
                Exposes the raw data buffer at the current _read position. The
                delegate is provided with a void[] representing the available
                data, and should return zero to leave the current _read position
                intact.

                If the delegate consumes data, it should return the number of
                bytes consumed; or IConduit.Eof to indicate an error.

        ***********************************************************************/

        final size_t read (size_t delegate (void[]) dg)
        {
                auto count = dg (data [index..extent]);

                if (count != Eof)
                   {
                   index += count;
                   assert (index <= extent);
                   }
                return count;
        }

        /***********************************************************************

                Transfer content into the provided dst

                Params:
                dst = destination of the content

                Returns:
                return the number of bytes read, which may be less than
                dst.length. Eof is returned when no further content is
                available.

                Remarks:
                Populates the provided array with content. We try to
                satisfy the request from the buffer content, and read
                directly from an attached conduit when the buffer is
                empty.

        ***********************************************************************/

        final override size_t read (void[] dst)
        {
                size_t content = readable;
                if (content)
                   {
                   if (content >= dst.length)
                       content = dst.length;

                   // transfer buffer content
                   dst [0 .. content] = data [index .. index + content];
                   index += content;
                   }
                else
                   // pathological cases read directly from conduit
                   if (dst.length > dimension)
                       content = source.read (dst);
                   else
                      {
                      if (writable is 0)
                          index = extent = 0;  // same as clear, without call-chain

                      // keep buffer partially populated
                      if ((content = write(&source.read)) != Eof && content > 0)
                           content = read (dst);
                      }
                return content;
        }

        /***********************************************************************

                Copy buffer content into the provided dst

                Params:
                dst = destination of the content
                bytes = size of dst

                Returns:
                A reference to the populated content

                Remarks:
                Fill the provided array with content. We try to satisfy
                the request from the buffer content, and read directly
                from an attached conduit where more is required.

        ***********************************************************************/
/+
        final BufferInput consume (void* dst, size_t bytes)
        {
                if (extract (dst [0 .. bytes]) != bytes)
                    conduit.error (eofRead);

                return this;
        }
+/
        /**********************************************************************

                Fill the provided buffer. Returns the number of bytes
                actually read, which will be less that dst.length when
                Eof has been reached and IConduit.Eof thereafter

        **********************************************************************/

        final size_t fill (void[] dst)
        {
                size_t len = 0;

                while (len < dst.length)
                      {
                      size_t i = read (dst [len .. $]);
                      if (i is Eof)
                          return (len > 0) ? len : Eof;
                      len += i;
                      }
                return len;
        }

        /***********************************************************************

                Move the current read location

                Params:
                size = the number of bytes to move

                Returns:
                Returns true if successful, false otherwise.

                Remarks:
                Skip ahead by the specified number of bytes, streaming from
                the associated conduit as necessary.

                Can also reverse the read position by 'size' bytes, when size
                is negative. This may be used to support lookahead operations.
                Note that a negative size will fail where there is not sufficient
                content available in the buffer (can't _skip beyond the beginning).

        ***********************************************************************/

        final bool skip (int size)
        {
                if (size < 0)
                   {
                   size = -size;
                   if (index >= size)
                      {
                      index -= size;
                      return true;
                      }
                   return false;
                   }
                return slice(size) !is null;
        }

        final override long seek (long offset, Anchor start = Anchor.Begin)
        {
                if (start is Anchor.Current)
                   {
                   // handle this specially because we know this is
                   // buffered - we should take into account the buffer
                   // position when seeking
                   offset -= readable;
                   auto bpos = offset + limit;

                   if (bpos >= 0 && bpos < limit)
                      {
                      // the new position is within the current
                      // buffer, skip to that position.
                      skip (cast(int) bpos - cast(int) position);
                      return Eof;
                      //return conduit.position - input.readable;
                      }
                   // else, position is outside the buffer. Do a real
                   // seek using the adjusted position.
                   }

                clear;
                return super.seek (offset, start);
        }

        /***********************************************************************

                Iterator support

                Params:
                scan = the delegate to invoke with the current content

                Returns:
                Returns true if a token was isolated, false otherwise.

                Remarks:
                Upon success, the delegate should return the byte-based
                index of the consumed pattern (tail end of it). Failure
                to match a pattern should be indicated by returning an
                Eof

                Each pattern is expected to be stripped of the delimiter.
                An end-of-file condition causes trailing content to be
                placed into the token. Requests made beyond Eof result
                in empty matches (length is zero).

                Note that additional iterator and/or reader instances
                will operate in lockstep when bound to a common buffer.

        ***********************************************************************/

        final bool next (size_t delegate (void[]) scan)
        {
                while (read(scan) is Eof)
                      {
                      // did we start at the beginning?
                      if (position)
                          // yep - move partial token to start of buffer
                          compress;
                      else
                         // no more space in the buffer?
                         if (writable is 0)
                             conduit.error ("BufferInput.next :: input buffer is full");

                      // read another chunk of data
                      if (write(&source.read) is Eof)
                          return false;
                      }
                return true;
        }

        /***********************************************************************

                Reserve the specified space within the buffer, compressing
                existing content as necessary to make room

                Returns the current read point, after compression if that
                was required

        ***********************************************************************/

        final size_t reserve (size_t space)
        {       
                assert (space < dimension);

                if ((dimension - index) < space)
                     compress;
                return index;
        }

        /***********************************************************************

                Compress buffer space

                Returns:
                the buffer instance

                Remarks:
                If we have some data left after an export, move it to
                front-of-buffer and set position to be just after the
                remains. This is for supporting certain conduits which
                choose to write just the initial portion of a request.

                Limit is set to the amount of data remaining. Position
                is always reset to zero.

        ***********************************************************************/

        final BufferInput compress ()
        {       
                size_t r = readable;

                if (index > 0 && r > 0)
                    // content may overlap ...
                    memcpy (&data[0], &data[index], r);

                index = 0;
                extent = r;
                return this;
        }

        /***********************************************************************

                Drain buffer content to the specific conduit

                Returns:
                Returns the number of bytes written, or Eof

                Remarks:
                Write as much of the buffer that the associated conduit
                can consume. The conduit is not obliged to consume all
                content, so some may remain within the buffer.

        ***********************************************************************/

        final size_t drain (OutputStream dst)
        {
                assert (dst);

                size_t ret = read (&dst.write);
                compress;
                return ret;
        }

        /***********************************************************************

                Access buffer limit

                Returns:
                Returns the limit of readable content within this buffer.

                Remarks:
                Each buffer has a capacity, a limit, and a position. The
                capacity is the maximum content a buffer can contain, limit
                represents the extent of valid content, and position marks
                the current read location.

        ***********************************************************************/

        final size_t limit ()
        {
                return extent;
        }

        /***********************************************************************

                Access buffer capacity

                Returns:
                Returns the maximum capacity of this buffer

                Remarks:
                Each buffer has a capacity, a limit, and a position. The
                capacity is the maximum content a buffer can contain, limit
                represents the extent of valid content, and position marks
                the current read location.

        ***********************************************************************/

        final size_t capacity ()
        {
                return dimension;
        }

        /***********************************************************************

                Access buffer read position

                Returns:
                Returns the current read-position within this buffer

                Remarks:
                Each buffer has a capacity, a limit, and a position. The
                capacity is the maximum content a buffer can contain, limit
                represents the extent of valid content, and position marks
                the current read location.

        ***********************************************************************/

        final size_t position ()
        {
                return index;
        }

        /***********************************************************************

                Available content

                Remarks:
                Return count of _readable bytes remaining in buffer. This is
                calculated simply as limit() - position()

        ***********************************************************************/

        final size_t readable ()
        {
                return extent - index;
        }

        /***********************************************************************

                Cast to a target type without invoking the wrath of the
                runtime checks for misalignment. Instead, we truncate the
                array length

        ***********************************************************************/

        static T[] convert(T)(void[] x)
        {
                return (cast(T*) x.ptr) [0 .. (x.length / T.sizeof)];
        }

        /***********************************************************************

                Clear buffer content

                Remarks:
                Reset 'position' and 'limit' to zero. This effectively
                clears all content from the buffer.

        ***********************************************************************/

        final override BufferInput clear ()
        {
                index = extent = 0;

                // clear the filter chain also
                super.clear;
                return this;
        }

        /***********************************************************************

                Set the input stream

        ***********************************************************************/

        final void input (InputStream source)
        {
                this.source = source;
        }

        /***********************************************************************

                Write into this buffer

                Params:
                dg = the callback to provide buffer access to

                Returns:
                Returns whatever the delegate returns.

                Remarks:
                Exposes the raw data buffer at the current _write position,
                The delegate is provided with a void[] representing space
                available within the buffer at the current _write position.

                The delegate should return the appropriate number of bytes
                if it writes valid content, or IConduit.Eof on error.

        ***********************************************************************/

        private final size_t write (size_t delegate (void[]) dg)
        {
                auto count = dg (data [extent..dimension]);

                if (count != Eof)
                   {
                   extent += count;
                   assert (extent <= dimension);
                   }
                return count;
        }

        /***********************************************************************

                Reset the buffer content

                Params:
                data =          the backing array to buffer within
                readable =      the number of bytes within data considered
                                valid

                Returns:
                the buffer instance

                Remarks:
                Set the backing array with some content readable. Writing
                to this will either flush it to an associated conduit, or
                raise an Eof condition. Use clear() to reset the content
                (make it all writable).

        ***********************************************************************/

        private final BufferInput set (void[] data, size_t readable)
        {
                this.data = data;
                this.extent = readable;
                this.dimension = data.length;

                // reset to start of input
                this.index = 0;

                return this;
        }

        /***********************************************************************

                Available space

                Remarks:
                Return count of _writable bytes available in buffer. This is
                calculated simply as capacity() - limit()

        ***********************************************************************/

        private final size_t writable ()
        {
                return dimension - extent;
        }
}



/*******************************************************************************

        Buffers the flow of data from a upstream output. A downstream 
        neighbour can locate and use this buffer instead of creating 
        another instance of their own.

        (note that upstream is closer to the source, and downstream is
        further away)

        Don't forget to flush() buffered content before closing.

*******************************************************************************/

class BufferOutput : OutputFilter, OutputBuffer
{
        alias OutputFilter.output output;

        private void[]        data;                   // the raw data buffer
        private size_t        index;                  // current read position
        private size_t        extent;                 // limit of valid content
        private size_t        dimension;              // maximum extent of content

        /***********************************************************************

                Ensure the buffer remains valid between method calls

        ***********************************************************************/

        invariant()
        {
                assert (index <= extent);
                assert (extent <= dimension);
        }

        /***********************************************************************

                Construct a buffer

                Params:
                stream = an input stream
                capacity = desired buffer capacity

                Remarks:
                Construct a Buffer upon the provided input stream.

        ***********************************************************************/

        this (OutputStream stream)
        {
                this (stream, stream.conduit.bufferSize);
        }

        /***********************************************************************

                Construct a buffer

                Params:
                stream = an input stream
                capacity = desired buffer capacity

                Remarks:
                Construct a Buffer upon the provided input stream.

        ***********************************************************************/

        this (OutputStream stream, size_t capacity)
        {
                set (new ubyte[capacity], 0);
                super (sink = stream);
        }

        /***********************************************************************

                Attempts to share an upstream BufferOutput, and creates a new
                instance where there's not a shared one available.

                Params:
                stream = an output stream

                Remarks:
                Where an upstream instance is visible it will be returned.
                Otherwise, a new instance is created based upon the bufferSize
                exposed by the associated conduit

        ***********************************************************************/

        static OutputBuffer create (OutputStream stream)
        {
                auto sink = stream;
                auto conduit = sink.conduit;
                while (cast(StreamMutator) sink is null)
                      {
                      auto b = cast(OutputBuffer) sink;
                      if (b)
                          return b;
                      if (sink is conduit)
                          break;
                      sink = sink.output;
                      assert (sink);
                      }
                      
                return new BufferOutput (stream, conduit.bufferSize);
        }

        /***********************************************************************

                Retrieve the valid content

                Returns:
                a void[] slice of the buffer

                Remarks:
                Return a void[] slice of the buffer, from the current position
                up to the limit of valid content. The content remains in the
                buffer for future extraction.

        ***********************************************************************/

        final void[] slice ()
        {
                return data [index .. extent];
        }

        /***********************************************************************

                Emulate OutputStream.write()

                Params:
                src = the content to write

                Returns:
                return the number of bytes written, which may be less than
                provided (conceptually).

                Remarks:
                Appends src content to the buffer, flushing to an attached
                conduit as necessary. An IOException is thrown upon write
                failure.

        ***********************************************************************/

        final override size_t write (void[] src)
        {
                append (src.ptr, src.length);
                return src.length;
        }

        /***********************************************************************

                Append content

                Params:
                src = the content to _append

                Returns a chaining reference if all content was written.
                Throws an IOException indicating eof or eob if not.

                Remarks:
                Append an array to this buffer, and flush to the
                conduit as necessary. This is often used in lieu of
                a Writer.

        ***********************************************************************/

        final BufferOutput append (void[] src)
        {
                return append (src.ptr, src.length);
        }

        /***********************************************************************

                Append content

                Params:
                src = the content to _append
                length = the number of bytes in src

                Returns a chaining reference if all content was written.
                Throws an IOException indicating eof or eob if not.

                Remarks:
                Append an array to this buffer, and flush to the
                conduit as necessary. This is often used in lieu of
                a Writer.

        ***********************************************************************/

        final BufferOutput append (void* src, size_t length)
        {
                if (length > writable)
                   {
                   flush;

                   // check for pathological case
                   if (length > dimension)
                       do {
                          auto written = sink.write (src [0 .. length]);
                          if (written is Eof)
                              conduit.error (eofWrite);
                          src += written, length -= written;
                          } while (length > dimension);
                    }

                // avoid "out of bounds" test on zero length
                if (length)
                   {
                   // content may overlap ...
                   memcpy (&data[extent], src, length);
                   extent += length;
                   }
                return this;
        }

        /***********************************************************************

                Consume content from a producer

                Params:
                The content to consume. This is consumed verbatim, and in
                raw binary format ~ no implicit conversions are performed.

                Remarks:
                This is often used in lieu of a Writer, and enables simple
                classes, such as FilePath and Uri, to emit content directly
                into a buffer (thus avoiding potential heap activity)

                Examples:
                ---
                auto path = new FilePath (somepath);

                path.produce (&buffer.consume);
                ---

        ***********************************************************************/

        final void consume (void[] x)
        {
                append (x);
        }

        /***********************************************************************

                Available space

                Remarks:
                Return count of _writable bytes available in buffer. This is
                calculated as capacity() - limit()

        ***********************************************************************/

        final size_t writable ()
        {
                return dimension - extent;
        }

        /***********************************************************************

                Access buffer limit

                Returns:
                Returns the limit of readable content within this buffer.

                Remarks:
                Each buffer has a capacity, a limit, and a position. The
                capacity is the maximum content a buffer can contain, limit
                represents the extent of valid content, and position marks
                the current read location.

        ***********************************************************************/

        final size_t limit ()
        {
                return extent;
        }

        /***********************************************************************

                Access buffer capacity

                Returns:
                Returns the maximum capacity of this buffer

                Remarks:
                Each buffer has a capacity, a limit, and a position. The
                capacity is the maximum content a buffer can contain, limit
                represents the extent of valid content, and position marks
                the current read location.

        ***********************************************************************/

        final size_t capacity ()
        {
                return dimension;
        }

        /***********************************************************************

                Truncate buffer content

                Remarks:
                Truncate the buffer within its extent. Returns true if
                the new length is valid, false otherwise.

        ***********************************************************************/

        final bool truncate (size_t length)
        {
                if (length <= data.length)
                   {
                   extent = length;
                   return true;
                   }
                return false;
        }

        /***********************************************************************

                Cast to a target type without invoking the wrath of the
                runtime checks for misalignment. Instead, we truncate the
                array length

        ***********************************************************************/

        static T[] convert(T)(void[] x)
        {
                return (cast(T*) x.ptr) [0 .. (x.length / T.sizeof)];
        }

        /***********************************************************************

                Flush all buffer content to the specific conduit

                Remarks:
                Flush the contents of this buffer. This will block until
                all content is actually flushed via the associated conduit,
                whereas drain() will not.

                Throws an IOException on premature Eof.

        ***********************************************************************/

        final override OutputStream flush ()
        {
                while (readable > 0)
                      {
                      auto ret = read (&sink.write);
                      if (ret is Eof)
                          conduit.error (eofWrite);
                      }

                // flush the filter chain also
                clear;
                super.flush;
                return this;
        }

        /***********************************************************************

                Copy content via this buffer from the provided src
                conduit.

                Remarks:
                The src conduit has its content transferred through
                this buffer via a series of fill & drain operations,
                until there is no more content available. The buffer
                content should be explicitly flushed by the caller.

                Throws an IOException on premature eof

        ***********************************************************************/

        final override OutputStream copy (InputStream src)
        {
                while (write(&src.read) != Eof)
                       // don't drain until we actually need to
                       if (writable is 0)
                           if (drain(sink) is Eof)
                               conduit.error (eofWrite);

                return this;
        }

        /***********************************************************************

                Drain buffer content to the specific conduit

                Returns:
                Returns the number of bytes written, or Eof

                Remarks:
                Write as much of the buffer that the associated conduit
                can consume. The conduit is not obliged to consume all
                content, so some may remain within the buffer.

        ***********************************************************************/

        final size_t drain (OutputStream dst)
        {
                assert (dst);

                size_t ret = read (&dst.write);
                compress;
                return ret;
        }

        /***********************************************************************

                Clear buffer content

                Remarks:
                Reset 'position' and 'limit' to zero. This effectively
                clears all content from the buffer.

        ***********************************************************************/

        final BufferOutput clear ()
        {
                index = extent = 0;
                return this;
        }

        /***********************************************************************

                Set the output stream

        ***********************************************************************/

        final void output (OutputStream sink)
        {
                this.sink = sink;
        }

        /***********************************************************************

                Seek within this stream. Any and all buffered output is 
                disposed before the upstream is invoked. Use an explicit
                flush() to emit content prior to seeking

        ***********************************************************************/

        final override long seek (long offset, Anchor start = Anchor.Begin)
        {       
                clear;
                return super.seek (offset, start);
        }

        /***********************************************************************

                Write into this buffer

                Params:
                dg = the callback to provide buffer access to

                Returns:
                Returns whatever the delegate returns.

                Remarks:
                Exposes the raw data buffer at the current _write position,
                The delegate is provided with a void[] representing space
                available within the buffer at the current _write position.

                The delegate should return the appropriate number of bytes
                if it writes valid content, or Eof on error.

        ***********************************************************************/

        final size_t write (size_t delegate (void[]) dg)
        {
                auto count = dg (data [extent..dimension]);

                if (count != Eof)
                   {
                   extent += count;
                   assert (extent <= dimension);
                   }
                return count;
        }

        /***********************************************************************

                Read directly from this buffer

                Params:
                dg = callback to provide buffer access to

                Returns:
                Returns whatever the delegate returns.

                Remarks:
                Exposes the raw data buffer at the current _read position. The
                delegate is provided with a void[] representing the available
                data, and should return zero to leave the current _read position
                intact.

                If the delegate consumes data, it should return the number of
                bytes consumed; or Eof to indicate an error.

        ***********************************************************************/

        private final size_t read (size_t delegate (void[]) dg)
        {
                auto count = dg (data [index..extent]);

                if (count != Eof)
                   {
                   index += count;
                   assert (index <= extent);
                   }
                return count;
        }

        /***********************************************************************

                Available content

                Remarks:
                Return count of _readable bytes remaining in buffer. This is
                calculated simply as limit() - position()

        ***********************************************************************/

        private final size_t readable ()
        {
                return extent - index;
        }

        /***********************************************************************

                Reset the buffer content

                Params:
                data =     the backing array to buffer within
                readable = the number of bytes within data considered
                           valid

                Returns:
                the buffer instance

                Remarks:
                Set the backing array with some content readable. Writing
                to this will either flush it to an associated conduit, or
                raise an Eof condition. Use clear() to reset the content
                (make it all writable).

        ***********************************************************************/

        private final BufferOutput set (void[] data, size_t readable)
        {
                this.data = data;
                this.extent = readable;
                this.dimension = data.length;

                // reset to start of input
                this.index = 0;

                return this;
        }

        /***********************************************************************

                Compress buffer space

                Returns:
                the buffer instance

                Remarks:
                If we have some data left after an export, move it to
                front-of-buffer and set position to be just after the
                remains. This is for supporting certain conduits which
                choose to write just the initial portion of a request.

                Limit is set to the amount of data remaining. Position
                is always reset to zero.

        ***********************************************************************/

        private final BufferOutput compress ()
        {       
                size_t r = readable;

                if (index > 0 && r > 0)
                    // content may overlap ...
                    memcpy (&data[0], &data[index], r);

                index = 0;
                extent = r;
                return this;
        }
}



/******************************************************************************

******************************************************************************/

debug (BufferStream)
{
        void main()
        {
                auto input = new BufferInput (null);
                auto output = new BufferOutput (null);
        }
}