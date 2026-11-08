export function titleId(title: string, designation: string): string

export interface MockServer {
	port: number
	state: {
		onAir: boolean
		current: { id: string; title: string; designation: string } | null
		last: { id: string; title: string; designation: string } | null
		recent: { id: string; title: string; designation: string; lastUsed: string }[]
		autoClearDefaultSeconds?: number
	}
	received: Array<Record<string, unknown>>
	clients: Set<unknown>
	options: { respondToPing: boolean }
	show(title: string, designation?: string): string | null
	broadcast(): void
	dropClients(): void
	close(): Promise<void>
}

export function startMockServer(opts?: {
	port?: number
	host?: string
	respondToPing?: boolean
	log?: boolean
}): Promise<MockServer>
