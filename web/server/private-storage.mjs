import { lstat, realpath } from "node:fs/promises";
import { isAbsolute, resolve, sep } from "node:path";
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

// The caller supplies a fresh, complete controller inventory for this host.
export async function privateDirectoryOutsideWorkspaces(path, workspaces) {
  if (!Array.isArray(workspaces) || workspaces.length === 0)
    throw new Error("Protected workspace inventory is unavailable");
  const directory = await privateDirectory(path);
  const contains = (parent, child) =>
    parent === child ||
    child.startsWith(parent.endsWith(sep) ? parent : parent + sep);
  for (const workspace of workspaces) {
    if (
      typeof workspace !== "string" ||
      !isAbsolute(workspace) ||
      (await realpath(workspace)) !== workspace
    )
      throw new Error("Protected workspace is not canonical");
    if (contains(workspace, directory) || contains(directory, workspace))
      throw new Error("Private storage must be separate from every workspace");
  }
  return directory;
}
