import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { startMockServer, titleId, type MockServer } from './mock-server.mjs'
import { LowerThirdsClient, type ClientStatus } from '../src/client.js'
import { buildActionDefinitions, type ActionContext } from '../src/actions.js'
import { buildFeedbackDefinitions } from '../src/feedbacks.js'
import { CUSTOM_CHOICE_ID, stateToVariables, type LowerThirdsState } from '../src/protocol.js'

/** Poll until predicate is true. */
async function waitFor(pred: () => boolean, timeoutMs = 5000, what = 'condition'): Promise<void> {
	const start = Date.now()
	while (!pred()) {
		if (Date.now() - start > timeoutMs) throw new Error(`Timed out waiting for ${what}`)
		await new Promise((r) => setTimeout(r, 10))
	}
}

type Logged = { level: string; message: string }

function setup(srv: MockServer, name = 'Main Desk', extra: Partial<ConstructorParameters<typeof LowerThirdsClient>[0]> = {}) {
	const client = new LowerThirdsClient({ host: '127.0.0.1', port: srv.port, name, reconnectDelayMs: 50, ...extra })
	const statuses: ClientStatus[] = []
	const logs: Logged[] = []
	const states: LowerThirdsState[] = []
	client.on('status', (s) => statuses.push(s))
	client.on('log', (level, message) => logs.push({ level, message }))
	client.on('state', (s) => states.push(s))
	const ctx: ActionContext = {
		getState: () => client.state,
		send: (m) => client.send(m),
		log: (level, message) => logs.push({ level, message }),
	}
	// Rebuild definitions on demand, as main.ts does when the recent list changes
	const actions = () => buildActionDefinitions(ctx)
	const run = async (id: keyof ReturnType<typeof actions>, options: Record<string, unknown> = {}) => {
		const def = actions()[id]
		if (!def) throw new Error(`no action ${String(id)}`)
		await def.callback({ id: 'a', controlId: 'c', actionId: String(id), surfaceId: undefined, options } as never, {
			type: 'action',
		} as never)
	}
	return { client, statuses, logs, states, actions, run }
}

describe('LowerThirdsClient against the mock server', () => {
	let srv: MockServer
	const clients: LowerThirdsClient[] = []

	beforeEach(async () => {
		srv = await startMockServer({ port: 0 })
	})
	afterEach(async () => {
		for (const c of clients.splice(0)) c.stop()
		await srv.close()
	})

	it('sends hello with the instance label and goes Ok on state', async () => {
		srv.show('Ps Luke de Jong', 'Lead Pastor')
		const t = setup(srv, 'Stage Left')
		clients.push(t.client)
		t.client.start()
		await waitFor(() => t.client.isConnected, 5000, 'connected')
		expect(srv.received[0]).toEqual({ type: 'hello', client: 'companion', name: 'Stage Left', protocol: 1 })
		expect(t.statuses[0]).toBe('connecting')
		expect(t.statuses.at(-1)).toBe('ok')
		expect(t.client.state.onAir).toBe(true)
		expect(stateToVariables(t.client.state).title).toBe('Ps Luke de Jong')
	})

	it('show (custom) / showRecent (id + position) / hide / toggle / remove / clear', async () => {
		const t = setup(srv)
		clients.push(t.client)
		t.client.start()
		await waitFor(() => t.client.isConnected)

		await t.run('show_title', { recent: CUSTOM_CHOICE_ID, title: '  Anna Smith ', designation: 'Worship' })
		await waitFor(() => srv.state.onAir && srv.state.current?.title === 'Anna Smith', 2000, 'anna on air')
		expect(srv.received.at(-1)).toEqual({ type: 'show', title: 'Anna Smith', designation: 'Worship' })
		await waitFor(() => t.client.state.recent.length === 1)

		await t.run('show_title', { recent: CUSTOM_CHOICE_ID, title: 'Ps Luke de Jong', designation: '' })
		await waitFor(() => t.client.state.recent.length === 2)

		// Dropdown choices reflect the new recent list after rebuilding definitions
		const showDef = t.actions().show_title
		if (!showDef) throw new Error('missing')
		const dropdown = showDef.options[0]
		expect(dropdown.type === 'dropdown' && dropdown.choices.map((c) => c.id)).toEqual([
			CUSTOM_CHOICE_ID,
			titleId('Ps Luke de Jong', ''),
			titleId('Anna Smith', 'Worship'),
		])
		expect(showDef.options[1].isVisibleExpression).toBe(`$(options:recent) == '${CUSTOM_CHOICE_ID}'`)

		// showRecent by id
		const annaId = titleId('Anna Smith', 'Worship')
		await t.run('show_title', { recent: annaId, title: 'ignored', designation: 'ignored' })
		await waitFor(() => srv.received.at(-1)?.type === 'showRecent')
		expect(srv.received.at(-1)).toEqual({ type: 'showRecent', id: annaId })
		await waitFor(() => t.client.state.current?.id === annaId)

		// Feedbacks
		const fbs = buildFeedbackDefinitions(() => t.client.state)
		const fbCtx = { type: 'feedback' } as never
		const fbEvent = (options: Record<string, unknown>) => ({ options }) as never
		expect(await (fbs.on_air as any).callback(fbEvent({}), fbCtx)).toBe(true)
		expect(await (fbs.title_on_air as any).callback(fbEvent({ recent: annaId }), fbCtx)).toBe(true)
		expect(
			await (fbs.title_on_air as any).callback(fbEvent({ recent: CUSTOM_CHOICE_ID, title: 'anna smith', designation: '' }), fbCtx)
		).toBe(true)
		expect(
			await (fbs.title_on_air as any).callback(fbEvent({ recent: titleId('Ps Luke de Jong', '') }), fbCtx)
		).toBe(false)

		// showRecent by position (2 = second most recent = Luke now)
		await t.run('show_recent_position', { position: 2 })
		await waitFor(() => 'index' in (srv.received.at(-1) ?? {}))
		expect(srv.received.at(-1)).toEqual({ type: 'showRecent', index: 1 })
		await waitFor(() => t.client.state.current?.title === 'Ps Luke de Jong')

		// Empty position: nothing sent
		const before = srv.received.length
		await t.run('show_recent_position', { position: 15 })
		expect(srv.received.length).toBe(before)

		await t.run('hide_title')
		await waitFor(() => !t.client.state.onAir)
		expect(stateToVariables(t.client.state).title).toBe('')

		await t.run('toggle_title')
		await waitFor(() => t.client.state.onAir && t.client.state.current?.title === 'Ps Luke de Jong')

		await t.run('remove_recent', { id: annaId })
		await waitFor(() => t.client.state.recent.length === 1)
		expect(srv.received.at(-1)).toEqual({ type: 'removeRecent', id: annaId })

		await t.run('clear_recent')
		await waitFor(() => t.client.state.recent.length === 0)
	})

	it('falls back gracefully on a stale recent id and an empty custom title', async () => {
		const t = setup(srv)
		clients.push(t.client)
		t.client.start()
		await waitFor(() => t.client.isConnected)
		const before = srv.received.length

		await t.run('show_title', { recent: 'gone1234' })
		await t.run('show_title', { recent: CUSTOM_CHOICE_ID, title: '   ' })
		await t.run('remove_recent', { id: 'gone1234' })
		await new Promise((r) => setTimeout(r, 100))

		expect(srv.received.length).toBe(before)
		expect(t.logs.filter((l) => l.level === 'warn').map((l) => l.message)).toEqual([
			expect.stringContaining('no longer in the Recent list'),
			expect.stringContaining('title is empty'),
			expect.stringContaining('not in the Recent list'),
		])
	})

	it('broadcasts state to multiple Companion instances', async () => {
		const a = setup(srv, 'A')
		const b = setup(srv, 'B')
		clients.push(a.client, b.client)
		a.client.start()
		b.client.start()
		await waitFor(() => a.client.isConnected && b.client.isConnected)

		await a.run('show_title', { recent: CUSTOM_CHOICE_ID, title: 'Shared', designation: '' })
		await waitFor(() => b.client.state.current?.title === 'Shared', 2000, 'B sees A’s title')
		expect(stateToVariables(b.client.state).recent_1_label).toBe('Shared')
	})

	it('reconnects after the server drops the connection', async () => {
		const t = setup(srv)
		clients.push(t.client)
		t.client.start()
		await waitFor(() => t.client.isConnected)

		srv.dropClients()
		await waitFor(() => t.statuses.includes('disconnected'), 2000, 'disconnected status')
		await waitFor(() => t.client.isConnected, 3000, 'reconnected')
		expect(srv.received.filter((m) => m.type === 'hello')).toHaveLength(2)
		expect(t.statuses.at(-1)).toBe('ok')
	})

	it('reports ConnectionFailure and keeps retrying when nothing is listening', async () => {
		const port = srv.port
		await srv.close()
		const t = setup({ ...srv, port } as MockServer)
		clients.push(t.client)
		t.client.start()
		await waitFor(() => t.statuses.filter((s) => s === 'connection_failure').length >= 2, 3000, 'two failures')
		expect(t.client.isConnected).toBe(false)
		// restart a server on the same port; the client should find it
		srv = await startMockServer({ port })
		await waitFor(() => t.client.isConnected, 5000, 'connected after server start')
	})

	it('treats missed pongs as a dead connection', async () => {
		srv.options.respondToPing = false
		const t = setup(srv, 'X', { pingIntervalMs: 100 })
		clients.push(t.client)
		t.client.start()
		await waitFor(() => t.client.isConnected)
		await waitFor(
			() => t.logs.some((l) => l.message.includes('no pong')),
			2000,
			'keepalive timeout'
		)
		await waitFor(() => t.statuses.includes('disconnected'), 2000)
		srv.options.respondToPing = true
		await waitFor(() => t.client.isConnected, 3000, 'reconnected')
	})

	it('drops actions with a warning while disconnected', async () => {
		const t = setup(srv)
		clients.push(t.client)
		await t.run('hide_title')
		expect(t.logs.at(-1)?.message).toContain('Not connected')
	})
})
