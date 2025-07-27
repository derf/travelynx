# Contributing to travelynx Development

First, a note upfront: travelynx is a hobby project.
While I appreciate suggestions, bug reports, and merge requests / patches, I want to make sure that it remains a hobby project and does not turn into a chore.
As such, please do not expect a timely response to anything you submit.
I typically only address issues and merge requests when I have the capacity for them _and_ when doing so does not feel like a chore.

That being said, I do appreciate bug reports, feature requests, and (simple!) patches, even if I may take quite a while to address or review them.
If you are planning a more involved patch set, please get in touch first.

## Translations

This is probably the easiest way to improve the life of any travelynx users who are not native German speakers.
Note that travelynx does _not_ use Weblate.

### Updating or Extending Translations

* Look at the [translation reference](/share/locales/reference.md)
* Pick a language that you'd like to fix / update / extend
* Adjust the corresponding `share/locales/ab-CD.po` file
* Open a merge request, either on [Codeberg](https://codeberg.org/derf/travelynx/pulls) or [GitHub](https://github.com/derf/travelynx/pulls)

### Adding a new Language

* Copy `share/locales/template.pot` to `share/locales/ab-CD.po`, replacing ab-CD with the appropriate language code
* Add the language / locale to  `$self->helper(loc_handle …` in `lib/Travelynx.pm`
* Add the language / locale to  `templates/language.html.ep`
* Provide as many translations as you feel comfortable with – partial translation files are fine; any entry left as `msgstr ""` will cause travelynx to fall back to English or German.
* Open a merge request, either on [Codeberg](https://codeberg.org/derf/travelynx/pulls) or [GitHub](https://github.com/derf/travelynx/pulls)

## Bug Reports

You may report bugs and request features either on [Codeberg](https://codeberg.org/derf/travelynx/issues) or [GitHub](https://github.com/derf/travelynx/issues).
