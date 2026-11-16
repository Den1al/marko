# Security: safe mode and folder trust

The full description of what Marko does and does not do on behalf of a document. The short
version is in the [README](../README.md#security); how it is built is in
[architecture.md](architecture.md#safe-mode-and-trust). This text is a promise to users: a code
change that makes a sentence here untrue changes the sentence in the same commit.

Marko is not sandboxed: it runs with your rights and can read and write whatever you can. What it
does on behalf of a document it did not write is therefore kept small, and the default for
anything you have not decided is **safe mode**.

## The trust question in three sentences

When a folder you open has no answer yet, a sheet offers **Open in Safe Mode** (the default;
Return and Escape) and **Trust Folder**. Trust does exactly one thing: documents in that folder
and below it may load the images they link to on the web and on network volumes. Safe mode
changes nothing else (editing, saving, local images and links work the same), and either answer
is remembered and can be changed in the File menu.

## Safe mode

Safe mode is how every file and folder opens until you say otherwise. In safe mode nothing is
fetched from the network for a document:

- images at `http:` and `https:` addresses, and at addresses without a scheme (`//host/path`);
- images at `file://host/…` addresses that name another host;
- images whose path leads onto a network volume (a mounted SMB, AFP, NFS or WebDAV share, or a
  place where the system would mount one when it is touched), directly or through a link. Marko
  finds that out from the system's list of mounted volumes and never touches the path itself.

No request is made, no name is looked up, no volume is mounted. Each such image shows a
placeholder that says "Remote image blocked" and from where (in a table cell an image is shown as
its markup, and is never loaded, trusted or not). Addresses of any other kind (`ftp:`, `smb:`,
`data:` and so on) are never fetched, in safe mode or out of it. A small shield beside the word
count marks a document in safe mode.

Safe mode is about the network, not about the files of your Mac: an image a document names by a
path on a local disk is read and shown wherever it is (`../other/x.png`, `/Users/you/Pictures/…`),
also outside the document's folder. Only a regular file is read, only if it is an image, and
nothing of it leaves the Mac. An image of more than 32 MB or 64 million pixels, local or remote,
is not read or decoded and shows as missing: a small file can unpack to gigabytes.

## Trust

Trust is given to a folder and covers the folders below it. It allows one thing: the documents
in that folder load the images they link to on the web (and from network volumes), which tells
those servers that, when and from which address you opened the document, and nothing they
could know you by the next time: the request is made by a loader of Marko's own that keeps and
sends no cookies, looks up no saved passwords and keeps no response on disk. Redirects are
followed.

- Opening a folder that has no answer yet asks once, on a sheet, after its window is there: *Trust
  Folder* or *Open in Safe Mode* (Return and Escape both mean safe mode). Either answer is
  remembered. A folder inside a trusted one is not asked about. A file opened on its own is never
  asked about: it is trusted if it lies in a trusted folder and in safe mode otherwise. The
  sheet shows the folder's path on one line, cut in the middle if long, after its own text.
- **File > Trust This Folder…** asks the same for the folder of the front window (the folder of
  its file, if it shows no tree); **Stop Trusting This Folder** makes that folder, and what is
  in it, safe again. Inside a trusted folder that is an exception: the folder above stays
  trusted for everything else in it, which is how one cloned repository is kept in safe mode
  inside a trusted folder of your own. The nearest answer above a document is the one that
  holds, and an answer for a folder replaces the earlier answers for the folders in it.
  **File > Trusted Folders** lists the trusted folders; choosing one stops trusting it, and
  *Stop Trusting All Folders* clears the list. (Exceptions are not listed; they are in
  `defaults read local.marko SafeFolders`.)
- Some folders cannot be trusted at all, by the sheet, the menu or the tool: the disk, a folder
  at its top (`/Users`, `/Volumes`, `/tmp`), and your home folder, the temporary folder and
  anything above them. Trusting one of those would switch safe mode off for whatever is
  downloaded. `marko --trust` on one opens it in safe mode, says so
  (`too much to trust, opened in safe mode`) and exits with status 1.
- **View > Load Remote Images**, or a click on a blocked image, loads the remote images of that
  one document until Marko quits. Nothing is remembered and no other document is affected; the
  menu item shows whether the front document loads them, and switches it off again. The choice
  goes by the document's path: if the file there is replaced while Marko runs (a `git pull`, a
  file moved onto it), the new text loads its remote images too. Stopping to trust the folder
  takes the choice back; declining to trust it does not.
- `marko --trust folder` and `marko --safe folder` answer for a folder without the sheet.
  For a file, `--trust` is Load Remote Images for that document and trusts no folder, and
  `--safe` keeps that document from loading them even inside a trusted folder; both last until
  Marko quits. Text piped in is treated like a file. Neither option is taken in a folder that
  holds a file named `--trust` or `--safe`: `marko *` there would pass the file's name as the
  option, so it is refused with a message (`marko -- *` opens the files).
- A change of trust reaches every open window at once: images load, or are replaced by
  placeholders and what was being fetched is given up.

Trust is for the folder that was at that path when you gave it. A folder that is moved or renamed
is asked about again, and another folder later made at the old path (or anywhere else) is not
trusted. A trusted folder restored from a backup or copied to another Mac is asked about again.
The answers are kept in Marko's settings (`defaults read local.marko TrustedFolders`); deleting
them is in the README under "Uninstall".

## What only happens when you do it yourself

- ⌘-click on a link opens `http:`, `https:` and `mailto:` addresses in your browser or mail
  program, and a linked Markdown file in Marko. A link to any other file shows that file in the
  Finder and never opens it; any other kind of address does nothing.
- A double click on a file in the sidebar that is not Markdown opens it only if it is a
  picture, sound, film, PDF or plain text, and then in the app your Mac has for that type of
  file, never in an app the file names for itself (the "Open With" setting, which travels with
  a file in an archive or a disk image). Anything else (apps, scripts, `.command`, `.terminal`,
  `.webloc`, HTML, SVG, playlists, archives, installers, files without an extension, and any
  link, which would open as what it leads to) is shown in the Finder instead. What the app
  that opens a file then does with it is that app's business: a film or sound file can itself
  refer to a stream (`.mov` reference movies, `.ram`), which its player may fetch.
- Reveal in Finder, Move to Trash, Rename, the Open panel and dropped files act on what you
  point at. Install Command Line Tool… runs the install script inside the app after asking.

## What Marko never does

No update check, no telemetry or crash reporting, no fetching of link titles, previews or icons,
no web view, no running of anything a document names. The only network request in the app is the
one for a remote image of a trusted (or explicitly loaded) document; it is made over `https` (an
`http:` address is tried over `https`), follows redirects, and takes at most 32 MB. Listing a
folder in the sidebar does not follow a link that leads onto a network volume. Spelling is
checked by the system's checker on your Mac.

## Limits

- The shield is only shown in a document's window, not on the empty page of a folder's window.
- While a document is in safe mode its images on a network volume are blocked even when the
  document itself is on that volume, until the folder is trusted.
