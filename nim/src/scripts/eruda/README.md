eruda.js is eruda 3.4.3 (https://github.com/liriliri/eruda, MIT licence), copied from the npm package with one fix: the Elements panel's `_back` (run when the selected node leaves the
page) called a nonexistent `set` ("undefined is not a function (evaluated from 'e.set')") and could loop past the
root; it now selects the nearest remaining ancestor, else <html>.
The right-click menu's "Inspect" injects it into the page (see nim/src/scripts/inspect.js and features/tabs/contextmenu.nim).
