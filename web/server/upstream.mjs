// These component endpoints are operator configuration, never browser input.
export function componentEndpoint(url) {
  const base = new URL(url);
  if (
    base.username ||
    base.password ||
    base.search ||
    base.hash ||
    (base.protocol !== "https:" &&
      !(
        base.protocol === "http:" &&
        ["127.0.0.1", "localhost", "[::1]"].includes(base.hostname)
      ))
  )
    throw new Error("Invalid service endpoint");
  return base;
}

export async function readComponentJson(response) {
  if (!response.ok) throw new Error("Upstream unavailable");
  const chunks = [];
  let length = 0;
  for await (const chunk of response.body) {
    length += chunk.length;
    if (length > 2 * 1024 * 1024)
      throw new Error("Resource response exceeds limit");
    chunks.push(chunk);
  }
  return JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)),
  );
}
