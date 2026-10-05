.pragma library

// The shell has one engine but a bar per monitor: share the setup retry clock.
var lastCallAt = 0
function due(now) { return now - lastCallAt >= 10000 }
function record(now) { lastCallAt = now }

// Successful step 5 waits for shutdown; step 6 waits until it asks questions.
function waiting(reply) {
    return reply.ok === true && (reply.step === "5"
        || (reply.step === "6" && (reply.questions || []).length === 0))
}
function shouldAdvance(reply, status) {
    if (!waiting(reply)) return false
    return (reply.step === "5" && status.active === false && status.state === "setup-needed")
        || (reply.step === "6" && status.active === true && status.state !== "stopping")
}
