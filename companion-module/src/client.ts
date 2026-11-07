/**
 * WebSocket client for LowerThirds.app. Independent of Companion so it can be
 * unit tested against the mock server.
 */
import { EventEmitter } from 'node:events'
import WebSocket from 'ws'
import {
	EMPTY_STATE,
	PROTOCOL_VERSION,
	parseServerMessage,
	type ClientMessage,
	type LowerThirdsState,
} from './protocol.js'

export type ClientStatus = 'connecting' | 'ok' | 'connection_failure' | 'disconnected'

export interface ClientOptions {
	host: string
	port: number
	/** Sent in `hello` as `name` (the Companion connection label). */
	name: string
	/** Keepalive interval; a missing pong by the next tick kills the socket. */
	pingIntervalMs?: number
	/** First reconnect delay; doubles each failure up to maxReconnectDelayMs. */
	reconnectDelayMs?: number
	maxReconnectDelayMs?: number
	/** WebSocket opening handshake timeout. */
	connectTimeoutMs?: number
}

export interface ClientEvents {
	status: [status: ClientStatus, message: string | null]
	state: [state: LowerThirdsState]
	serverError: [message: string]
	log: [level: 'debug' | 'info' | 'warn' | 'error', message: string]
}

export class LowerThirdsClient extends EventEmitter<ClientEvents> {
	#opts: Required<ClientOptions>
	#ws: WebSocket | null = null
	#state: LowerThirdsState = EMPTY_STATE
	#status: ClientStatus = 'disconnected'
	#connected = false
	#stopped = true
	#reconnectTimer: NodeJS.Timeout | null = null
	#pingTimer: NodeJS.Timeout | null = null
	#awaitingPong = false
	#failures = 0

	constructor(opts: ClientOptions) {
		super()
		this.#opts = {
			pingIntervalMs: 10_000,
			reconnectDelayMs: 1_000,
			maxReconnectDelayMs: 30_000,
			connectTimeoutMs: 5_000,
			...opts,
		}
	}

	get state(): LowerThirdsState {
		return this.#state
	}

	get status(): ClientStatus {
		return this.#status
	}

	/** True once the socket is open and we've received a `state` after `hello`. */
	get isConnected(): boolean {
		return this.#connected
	}

	get url(): string {
		const host = this.#opts.host.includes(':') && !this.#opts.host.startsWith('[') ? `[${this.#opts.host}]` : this.#opts.host
		return `ws://${host}:${this.#opts.port}/ws`
	}

	start(): void {
		this.#stopped = false
		this.#failures = 0
		this.#connect()
	}

	stop(): void {
		this.#stopped = true
		this.#clearTimers()
		this.#teardownSocket()
		this.#connected = false
		this.#setStatus('disconnected', null)
	}

	/** Update the label sent in hello; re-sends hello if connected. */
	setName(name: string): void {
		if (name === this.#opts.name) return
		this.#opts.name = name
		if (this.#ws?.readyState === WebSocket.OPEN) this.#sendHello()
	}

	/** Send a protocol message. Returns false (and logs) if not connected. */
	send(msg: ClientMessage): boolean {
		const ws = this.#ws
		if (!ws || ws.readyState !== WebSocket.OPEN) {
			this.emit('log', 'warn', `Not connected to LowerThirds; dropped "${msg.type}"`)
			return false
		}
		ws.send(JSON.stringify(msg))
		return true
	}

	#setStatus(status: ClientStatus, message: string | null): void {
		this.#status = status
		this.emit('status', status, message)
	}

	#connect(): void {
		if (this.#stopped) return
		this.#teardownSocket()
		this.#setStatus('connecting', this.url)
		this.emit('log', 'debug', `Connecting to ${this.url}`)

		let ws: WebSocket
		try {
			ws = new WebSocket(this.url, { handshakeTimeout: this.#opts.connectTimeoutMs })
		} catch (e) {
			this.#handleDisconnect(`Invalid address: ${(e as Error).message}`)
			return
		}
		this.#ws = ws
		let lastError: string | null = null

		ws.on('open', () => {
			if (ws !== this.#ws) return
			this.emit('log', 'info', `Connected to ${this.url}`)
			this.#awaitingPong = false
			this.#sendHello()
			this.#startPing()
		})

		ws.on('message', (data, isBinary) => {
			if (ws !== this.#ws || isBinary) return
			this.#awaitingPong = false // any traffic proves the link is alive
			const msg = parseServerMessage(data.toString())
			if (!msg) {
				this.emit('log', 'debug', `Ignoring unrecognised message: ${data.toString().slice(0, 200)}`)
				return
			}
			switch (msg.type) {
				case 'state': {
					const { type: _t, ...state } = msg
					this.#state = state
					if (!this.#connected) {
						this.#connected = true
						this.#failures = 0
						this.#setStatus('ok', null)
					}
					this.emit('state', state)
					break
				}
				case 'error':
					this.emit('serverError', msg.message)
					break
				case 'pong':
					break
			}
		})

		ws.on('error', (err) => {
			lastError = err.message || String(err)
		})

		ws.on('close', (code, reason) => {
			if (ws !== this.#ws) return
			const why = lastError ?? (reason.toString() || `closed (code ${code})`)
			this.#handleDisconnect(why)
		})
	}

	#sendHello(): void {
		this.send({ type: 'hello', client: 'companion', name: this.#opts.name, protocol: PROTOCOL_VERSION })
	}

	#startPing(): void {
		if (this.#pingTimer) clearInterval(this.#pingTimer)
		this.#pingTimer = setInterval(() => {
			const ws = this.#ws
			if (!ws || ws.readyState !== WebSocket.OPEN) return
			if (this.#awaitingPong) {
				this.emit('log', 'warn', 'Keepalive: no pong received, treating connection as dead')
				ws.terminate() // fires 'close' -> reconnect
				return
			}
			this.#awaitingPong = true
			this.send({ type: 'ping' })
		}, this.#opts.pingIntervalMs)
	}

	#handleDisconnect(reason: string): void {
		const wasConnected = this.#connected
		this.#connected = false
		if (this.#pingTimer) {
			clearInterval(this.#pingTimer)
			this.#pingTimer = null
		}
		this.#ws?.removeAllListeners()
		this.#ws = null
		if (this.#stopped) return

		const delay = Math.min(this.#opts.reconnectDelayMs * 2 ** this.#failures, this.#opts.maxReconnectDelayMs)
		this.#failures++
		const secs = Math.round(delay / 100) / 10
		if (wasConnected) {
			this.emit('log', 'warn', `Disconnected from LowerThirds (${reason}); reconnecting in ${secs}s`)
			this.#setStatus('disconnected', `${reason} — retrying in ${secs}s`)
		} else {
			this.emit('log', 'debug', `Connection failed (${reason}); retrying in ${secs}s`)
			this.#setStatus('connection_failure', `${reason} — retrying in ${secs}s`)
		}
		if (this.#reconnectTimer) clearTimeout(this.#reconnectTimer)
		this.#reconnectTimer = setTimeout(() => {
			this.#reconnectTimer = null
			this.#connect()
		}, delay)
	}

	#teardownSocket(): void {
		const ws = this.#ws
		this.#ws = null
		if (!ws) return
		ws.removeAllListeners()
		ws.on('error', () => {}) // swallow late errors from a socket we've abandoned
		try {
			if (ws.readyState === WebSocket.OPEN) ws.close(1000, 'bye')
			else ws.terminate()
		} catch {
			// ignore
		}
	}

	#clearTimers(): void {
		if (this.#reconnectTimer) clearTimeout(this.#reconnectTimer)
		if (this.#pingTimer) clearInterval(this.#pingTimer)
		this.#reconnectTimer = null
		this.#pingTimer = null
	}
}
