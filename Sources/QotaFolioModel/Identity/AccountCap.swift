import Foundation

// One spelling of the cap. Written out as a literal it would sit in the catalog's guard, in the
// error it throws, and again in the fixture — three places that have to be changed together and
// no way to notice when they are not.
//
// It sits in the model target because everything that reads this app's files is bounded by it:
// the catalog codec refuses a sixth row, and each history book keeps at most this many accounts.
public nonisolated let qotaFolioMaximumAccounts = 5
