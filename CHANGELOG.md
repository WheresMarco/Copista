# Changelog

Each version's section here is what Copista shows when it offers that update, and what its GitHub
release says. `scripts/release.sh` reads it, so add the new version's section before running it.

## 1.0.0

The first release.

- Drop in PDFs or folders. Files added together are one song, and a folder is sorted into songs.
- Pages are sorted into instrument parts from bookmarks, file names, the PDF's text, or by reading
  scans with on-device OCR. A part runs until a new name appears at the top of a page.
- Review shows every part by section, flags anything uncertain with how to fix it, and lets you set
  instruments, drag pages between parts, reorder, rotate and exclude, with undo for all of it.
- Corrections are remembered per file. Names you teach Copista are recognized from then on.
- Copies per instrument, with defaults set once in a short welcome guide.
- Each song prints as its own job and saves as its own PDF, with blank backs for double-sided
  printing where needed.
- 61 built-in wind-band instruments, and your own.
- English and Swedish.
