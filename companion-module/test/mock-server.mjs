#!/usr/bin/env node
/**
 * Mock LowerThirds.app implementing protocol v1 (docs/PROTOCOL.md):
 * WebSocket at /ws plus the HTTP /api endpoints.
 *
 *   node test/mock-server.mjs [port]      (default 9123)
 *
 * Also importable: `const srv = await startMockServer({ port: 0 })`.
 */
import { createHash } from 'node:crypto'
import { createServer } from 'node:http'
import { fileURLToPath } from 'node:url'
import { WebSocketServer } from 'ws'

const MAX_RECENT = 20

export function titleId(title, designation) {
	return createHash('sha256')
		.update(`${title.trim().toLowerCase()}\n${designation.trim().toLowerCase()}`)
		.digest('hex')
		.slice(0, 8)
}

export async function startMockServer({ port = 9123, host = '127.0.0.1', respondToPing = true, log = false } = {}) {
	const state = { onAir: false, current: null, last: null, recent: [] }
	/** every message received from any client, for assertions */
	const received = []
	const clients = new Set()
	const opts = { respondToPing }

	const snapshot = () => ({ type: 'state', protocol: 1, ...structuredClone(state) })
	const broadcast = () => {
		const msg = JSON.stringify(snapshot())
		for (const ws of clients) if (ws.readyState === ws.OPEN) ws.send(msg)
	}

	function show(title, designation = '') {
		title = String(title ?? '').trim()
		designation = String(designation ?? '').trim()
		if (!title) return 'title is required'
		const entry = { id: titleId(title, designation), title, designation }
		state.recent = state.recent.filter((e) => e.id !== entry.id)
		state.recent.unshift({ ...entry, lastUsed: new Date().toISOString() })
		state.recent.length = Math.min(state.recent.length, MAX_RECENT)
		state.current = entry
		state.last = entry
		state.onAir = true
		return null
	}
	function hide() {
		state.onAir = false
		state.current = null
	}

	/** Apply one client message. Returns an error string, or null. */
	function apply(msg) {
		switch (msg.type) {
			case 'show':
				return show(msg.title, msg.designation)
			case 'showRecent': {
				const e =
					typeof msg.id === 'string'
						? state.recent.find((r) => r.id === msg.id)
						: typeof msg.index === 'number'
							? state.recent[msg.index]
							: undefined
				if (!e) return 'recent entry not found'
				return show(e.title, e.designation)
			}
			case 'hide':
				hide()
				return null
			case 'toggle':
				if (state.onAir) hide()
				else if (state.last) show(state.last.title, state.last.designation)
				return null
			case 'removeRecent':
				state.recent = state.recent.filter((r) => r.id !== msg.id)
				return null
			case 'clearRecent':
				state.recent = []
				return null
			default:
				return `unknown type: ${msg.type}`
		}
	}

	const http = createServer((req, res) => {
		const send = (code, body) => {
			res.writeHead(code, { 'content-type': 'application/json' })
			res.end(JSON.stringify(body))
		}
		let body = ''
		req.on('data', (c) => (body += c))
		req.on('end', () => {
			let json = {}
			try {
				json = body ? JSON.parse(body) : {}
			} catch {
				return send(400, { error: 'bad json' })
			}
			const routes = {
				'GET /api/state': () => null,
				'POST /api/show': () => apply({ type: 'show', ...json }),
				'POST /api/hide': () => apply({ type: 'hide' }),
				'POST /api/toggle': () => apply({ type: 'toggle' }),
				'POST /api/recent/clear': () => apply({ type: 'clearRecent' }),
			}
			const fn = routes[`${req.method} ${req.url}`]
			if (!fn) return send(404, { error: 'not found' })
			const err = fn()
			if (err) return send(400, { error: err })
			if (req.method === 'POST') broadcast()
			send(200, snapshot())
		})
	})

	const wss = new WebSocketServer({ server: http, path: '/ws' })
	wss.on('connection', (ws) => {
		clients.add(ws)
		ws.on('close', () => clients.delete(ws))
		ws.on('message', (data) => {
			let msg
			try {
				msg = JSON.parse(data.toString())
			} catch {
				return ws.send(JSON.stringify({ type: 'error', message: 'invalid JSON' }))
			}
			received.push(msg)
			if (log) console.log('<-', JSON.stringify(msg))
			if (msg.type === 'hello') return ws.send(JSON.stringify(snapshot()))
			if (msg.type === 'ping') {
				if (opts.respondToPing) ws.send(JSON.stringify({ type: 'pong' }))
				return
			}
			const err = apply(msg)
			if (err) return ws.send(JSON.stringify({ type: 'error', message: err }))
			broadcast()
		})
	})

	await new Promise((resolve, reject) => {
		http.once('error', reject)
		http.listen(port, host, resolve)
	})

	return {
		port: http.address().port,
		state,
		received,
		clients,
		options: opts,
		show,
		broadcast,
		/** Forcefully drop all client sockets (simulates app crash / network blip). */
		dropClients() {
			for (const ws of clients) ws.terminate()
		},
		async close() {
			for (const ws of clients) ws.terminate()
			await new Promise((r) => wss.close(() => r()))
			await new Promise((r) => http.close(() => r()))
		},
	}
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
	const port = Number(process.argv[2] ?? 9123)
	const srv = await startMockServer({ port, host: '0.0.0.0', log: true })
	console.log(`Mock LowerThirds listening on ws://0.0.0.0:${srv.port}/ws`)
}
