import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { resolve } from "node:path";
import test from "node:test";

// Exercise the optimized executable: debug-only tests cannot detect linked async frame mismatches.
test("ten WebSocket disconnects leave the release HTTP server available", {
	timeout: 30_000,
}, async (context) => {
	const child = spawn(resolve(process.argv[2] ?? "./Baguette"), [
		"serve",
		"--port",
		"0",
		"--no-plugins",
	]);
	const exited = once(child, "exit");
	context.signal.addEventListener("abort", () => child.kill("SIGTERM"), {
		once: true,
	});
	let output = "";
	const ready = Promise.withResolvers();
	const collect = (chunk) => {
		output += String(chunk);
		const port = /Server started and listening on 127.0.0.1:(\d+)/.exec(
			output,
		)?.[1];
		if (port) ready.resolve(port);
	};
	child.stdout.on("data", collect);
	child.stderr.on("data", collect);
	child.once("error", ready.reject);
	child.once("exit", (code, signal) =>
		ready.reject(new Error(`Server exited (${code ?? signal}): ${output}`)),
	);
	const timeout = setTimeout(
		() => ready.reject(new Error(`Server did not start: ${output}`)),
		10_000,
	);
	try {
		const port = await ready.promise;
		clearTimeout(timeout);
		for (let attempt = 0; attempt < 10; attempt++) {
			const socket = new WebSocket(
				`ws://127.0.0.1:${port}/simulators/00000000-0000-0000-0000-000000000000/stream?format=mjpeg`,
			);
			const closed = new Promise((resolve, reject) => {
				socket.addEventListener("close", resolve, { once: true });
				socket.addEventListener("error", reject, { once: true });
			});
			socket.addEventListener("message", () => socket.close());
			await closed;
			const response = await fetch(`http://127.0.0.1:${port}/simulators.json`, {
				signal: AbortSignal.timeout(3000),
			});
			assert.equal(
				response.status,
				200,
				`HTTP after disconnect ${attempt + 1}: ${output}`,
			);
			const simulators = await response.json();
			assert.ok(Array.isArray(simulators.running));
			assert.ok(Array.isArray(simulators.available));
			assert.equal(child.exitCode, null, output);
			assert.equal(child.signalCode, null, output);
		}
	} catch (error) {
		throw new Error(`Release WebSocket lifecycle failed: ${output}`, {
			cause: error,
		});
	} finally {
		clearTimeout(timeout);
		if (child.exitCode === null && child.signalCode === null)
			child.kill("SIGTERM");
		await exited;
	}
});
