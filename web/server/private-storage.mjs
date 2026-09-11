import { lstat, realpath } from "node:fs/promises";
import { resolve, sep } from "node:path";
import { tmpdir } from "node:os";

export async function privateDirectory(path) {
  const canonical = await realpath(path);
  // The pinned native provider grants access to shared system scratch paths.
  if (
    canonical !== resolve(path) ||
    [
      "/tmp",
      "/private/tmp",
      "/var/tmp",
      "/private/var/tmp",
      "/private/var/folders",
      await realpath(tmpdir()),
    ].some((root) => canonical === root || canonical.startsWith(root + sep))
  )
    throw new Error(
      "Private spool must be canonical and outside shared scratch",
    );
  const info = await lstat(canonical);
  if (
    !info.isDirectory() ||
    info.isSymbolicLink() ||
    info.uid !== process.getuid() ||
    info.mode & 0o077
  )
    throw new Error("Private spool must be an owner-only directory");
  return canonical;
}
