// android-as-linux.js
// Loaded through NODE_OPTIONS="--require ..." before code-server starts.
// Makes Node.js report the platform as "linux" so that non-web extensions
// can be installed.
Object.defineProperty(process, "platform", {
  get() {
    return "linux"
  },
})
