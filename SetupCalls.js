.pragma library

// The shell has one engine but a bar per monitor: share the setup retry clock.
var lastCallAt = 0
function due(now) { return now - lastCallAt >= 10000 }
function record(now) { lastCallAt = now }
