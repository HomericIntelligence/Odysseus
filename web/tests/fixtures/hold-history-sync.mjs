// Loaded only by process tests; all file operations still use the real filesystem.
import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";

const open = fs.open;
fs.open = async (path, ...options) => {
  const handle = await open(path, ...options);
  if (String(path).endsWith(".json.tmp")) {
    const sync = handle.sync.bind(handle);
    handle.sync = async () => {
      process.channel.ref();
      process.send({ type: "history-sync-blocked" });
      await new Promise((resolve) => {
        process.once("message", resolve);
      });
      await sync();
      process.channel.unref();
    };
  }
  return handle;
};
syncBuiltinESMExports();
process.channel.unref();
