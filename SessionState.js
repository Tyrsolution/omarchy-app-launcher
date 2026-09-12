.pragma library

// Shared by successive overlay instances in this Quickshell engine. No disk
// write: reopening preserves collapse; restarting the shell resets it.
var stripCollapsed = false
