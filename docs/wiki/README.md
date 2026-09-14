# Wiki source

These pages are the **source** for the GitHub wiki at
<https://github.com/impressiver/snitt/wiki>. Edit them here, in a pull request,
and run `Scripts/publish-wiki.sh` to push.

**Why the source lives in the repo rather than in the wiki.** A GitHub wiki is
a separate git repository with no pull requests and no review. Anyone with push
access can rewrite a page and nobody sees a diff. Snitt documents things whose
wrongness is expensive — which permissions it asks for, what a recording
contains, what leaves the machine — so the copy people read is generated from
one that went through review.

The wiki is the published form. This is the master. Editing a page directly in
the wiki will be overwritten by the next publish.

Filenames map to page titles: `Home.md` is the landing page, and
`Recording-a-screen.md` becomes "Recording a screen".
