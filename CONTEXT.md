# NoteBank

A private, single-user capture tool: save text, links, images and files from any device into one feed, organised by optional Topics, synced everywhere and searchable later.

## Language

### Content

**Item**:
One saved thing in the feed: an optional body of text plus zero or more Attachments. The text is the primary content; Attachments hang off it.
_Avoid_: Note, message, post, entry

**Attachment**:
A file (image, document, etc.) that belongs to exactly one Item.
_Avoid_: Media, upload, file item

**Link**:
A URL inside an Item's text. Not a separate kind of Item.
_Avoid_: URL item, bookmark

### Organisation

**Topic**:
A named bucket an Item can be filed under (e.g. "Mosaic", "CS 111"). An Item has at most one Topic; the same content in two Topics is two Items.
_Avoid_: Channel, tag, folder, category

**Inbox**:
The set of Items that are neither in the Tunnel nor filed under a Topic. Not a Topic itself.
_Avoid_: Uncategorised, default topic

**Tunnel**:
One built-in place for quick transfer between Devices. Tapping or clicking an Item copies its text; the synced Trash-after-copy setting can then move it to Trash, with Undo. It is separate from the Inbox and Topics.
_Avoid_: Channel, temporary Topic

**Archived Topic**:
A Topic that is hidden and closed to new Items until unarchived; its existing Items are kept and remain searchable.
_Avoid_: Closed topic, hidden topic

**Feed**:
The chronological, Discord-style view of Items, either all of them, one Topic's, the Inbox, or the Tunnel, ordered by Capture Time.
_Avoid_: Timeline, stream

**Trash**:
Where deleted Items, including Items left empty by an edit, wait for 30 days, restorable, before being permanently purged along with their Attachments.
_Avoid_: Bin, recycle bin, archive

### Sync

**Capture**:
The act of saving a new Item on a device. A Capture always succeeds locally first, online or offline.
_Avoid_: Upload, post, send

**Capture Time**:
The moment an Item was Captured, as recorded by the Device, not when the Server received it.
_Avoid_: Created at, sent at, timestamp

**Account settings**:
Preferences synced through the Server in one row. The later Device-clock change wins. Trash after copy is unasked until answered, then on or off.
_Avoid_: Device settings, local preferences

**Server**:
The single remote instance that holds the authoritative copy of every Item and Attachment.
_Avoid_: Backend, cloud, remote

**Device**:
A client install (desktop or iOS) belonging to the one user, with its own local copy of what it has captured or cached.
_Avoid_: Client, node
