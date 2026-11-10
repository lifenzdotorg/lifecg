# ProPresenter 7 file format

`presentation.json` is a protobuf.js descriptor holding `rv.data.Presentation` and the types it uses, pruned
from the community-maintained ProPresenter 7 schema at https://github.com/greyshirtguy/ProPresenter7-Proto
(MIT licence). Regenerate it from those `.proto` files if ProPresenter changes its format.

`shared/probundle.ts` builds a `.probundle` (a zip of the `.pro` file and its media) from portal slides. Its
element defaults copy what ProPresenter 21.x wrote in LIFE's own exports (South and Central, Nov 2026).
