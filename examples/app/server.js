const http = require("node:http");

const port = Number(process.env.PORT) || 3000;

http
  .createServer((req, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ message: "hello from a Docker Hardened Image", node: process.version }));
  })
  .listen(port, () => console.log(`listening on :${port}`));
