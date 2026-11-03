const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(
  require("node:path").join(__dirname, "../ui/app.js"),
  "utf8",
);
const start = source.indexOf("function workflowStepStates(");
const end = source.indexOf("\nconst ", start);
const context = vm.createContext({});
vm.runInContext(source.slice(start, end), context);
const states = (run, lines) =>
  Array.from(context.workflowStepStates(run, lines));
assert.deepEqual(
  states({ action: "full", active: true }, ["[studio-stage:3:running]"]),
  ["completed", "completed", "running", "pending", "pending"],
);
assert.deepEqual(
  states({ action: "full", status: "failed" }, [
    "[studio-stage:4:running]",
    "[studio-stage:4:failed]",
  ]),
  ["completed", "completed", "completed", "failed", "pending"],
);
assert.deepEqual(states({ Action: "package", Status: "succeeded" }), [
  "skipped",
  "skipped",
  "skipped",
  "skipped",
  "completed",
]);
assert.deepEqual(
  states({ action: "full", status: "dry-run" }),
  Array(5).fill("preview"),
);
assert.deepEqual(
  states({ action: "full", status: "interrupted" }, [
    "[studio-stage:2:running]",
  ]),
  ["completed", "interrupted", "pending", "pending", "pending"],
);
assert.deepEqual(
  states({ action: "build", active: true, paused: true }, [
    "Configuring CMake...",
  ]),
  ["completed", "completed", "skipped", "paused", "skipped"],
);
assert.deepEqual(
  states({ action: "full", status: "failed" }),
  Array(5).fill("pending"),
);
console.log("Workflow stage checks passed.");
// A compiler counter must never become a shrinking overall progress bar.
const nodes = new Map();
context.$ = (selector) => {
  if (!nodes.has(selector))
    nodes.set(selector, {
      classList: {
        remove() {},
        toggle(name, value) {
          this[name] = value;
        },
      },
      style: {},
      setAttribute() {},
      querySelector() {
        return context.$("#testBar");
      },
    });
  return nodes.get(selector);
};
context.formatElapsed = () => "1m";
vm.runInContext(
  source.slice(
    source.indexOf("function drawProgress("),
    source.indexOf("function tag("),
  ),
  context,
);
context.drawProgress({
  active: true,
  profile: "test",
  action: "full",
  output: ["Configuring CMake...", "[4/10] Compiling a plugin"],
  started: new Date().toISOString(),
});
assert.equal(nodes.get("#testBar").style.width, "100%");
assert.equal(nodes.get("#buildProgress").classList["activity-motion"], true);
assert.equal(nodes.get("#progressEta").textContent, "Building project");
assert.ok(!nodes.get("#progressPercent").textContent.includes("%"));
context.drawProgress({
  active: true,
  paused: true,
  action: "full",
  output: ["Configuring CMake..."],
});
assert.equal(nodes.get("#buildProgress").classList["activity-motion"], false);
assert.match(nodes.get("#progressEta").textContent, /Paused/);
console.log("Activity indicator checks passed.");

assert.deepEqual(
  states({ action: "full", active: true, workflowStage: 4 }, [
    "[1/2] Compiler task",
  ]),
  ["completed", "completed", "completed", "running", "pending"],
);
