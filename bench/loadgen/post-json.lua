-- POST the JSON payload named by BENCH_BODY_FILE on every request
-- (the runner points it at payloads/b1-order.json).
local path = os.getenv("BENCH_BODY_FILE")
local f = assert(io.open(path, "rb"),
                 "BENCH_BODY_FILE not readable: " .. tostring(path))
wrk.method = "POST"
wrk.body = f:read("*a")
f:close()
wrk.headers["Content-Type"] = "application/json"
