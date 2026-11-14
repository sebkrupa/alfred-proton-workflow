// Clipboard helper (JXA). Run with: osascript -l JavaScript clip.js <mode> [arg]
//
//   copy        read the value from stdin (never argv, so it is not visible in
//               `ps`), put it on the clipboard for this Mac only (no Universal
//               Clipboard), and mark it concealed + transient so clipboard
//               managers (incl. Alfred Clipboard History) skip it.
//               Prints the pasteboard changeCount.
//   clear <n>   clear the clipboard only if its changeCount is still <n>, i.e.
//               nothing was copied since. The secret is never kept in memory.
ObjC.import('AppKit');

function run(argv) {
  const pb = $.NSPasteboard.generalPasteboard;
  if (argv[0] === 'copy') {
    const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    const value = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
    pb.prepareForNewContentsWithOptions(1); // 1 = NSPasteboardContentsCurrentHostOnly
    pb.setStringForType(value, 'public.utf8-plain-text');
    pb.setStringForType($(''), 'org.nspasteboard.ConcealedType');
    pb.setStringForType($(''), 'org.nspasteboard.TransientType');
    return String(pb.changeCount);
  }
  if (argv[0] === 'clear') {
    if (String(pb.changeCount) === argv[1]) pb.clearContents;
    return '';
  }
  throw new Error('usage: clip.js copy | clear <changeCount>');
}
