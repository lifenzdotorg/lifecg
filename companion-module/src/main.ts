import { InstanceBase, InstanceStatus, type SomeCompanionConfigField } from '@companion-module/base'
import { GetConfigFields, DEFAULT_PORT, type ModuleConfig } from './config.js'
import { UpgradeScripts } from './upgrades.js'
import { buildActionDefinitions, type ActionsSchema } from './actions.js'
import { buildFeedbackDefinitions, type FeedbacksSchema } from './feedbacks.js'
import { buildPresets } from './presets.js'
import { LifeCGClient, type ClientStatus } from './client.js'
import {
	EMPTY_STATE,
	recentSignature,
	stateToVariables,
	variableDefinitions,
	type LifeCGState,
	type VariableValues,
} from './protocol.js'

export type ModuleSchema = {
	config: ModuleConfig
	secrets: undefined
	actions: ActionsSchema
	feedbacks: FeedbacksSchema
	variables: VariableValues
}

export { UpgradeScripts }

const STATUS_MAP: Record<ClientStatus, InstanceStatus> = {
	connecting: InstanceStatus.Connecting,
	ok: InstanceStatus.Ok,
	connection_failure: InstanceStatus.ConnectionFailure,
	disconnected: InstanceStatus.Disconnected,
}

export default class LifeCGInstance extends InstanceBase<ModuleSchema> {
	config!: ModuleConfig
	#client: LifeCGClient | null = null
	#state: LifeCGState = EMPTY_STATE
	#recentSig = ''
	#lastLabel = ''

	constructor(internal: unknown) {
		super(internal)
	}

	async init(config: ModuleConfig): Promise<void> {
		this.config = config
		this.#lastLabel = this.label

		this.setVariableDefinitions(variableDefinitions())
		this.#applyState(EMPTY_STATE, true)
		const { structure, presets } = buildPresets()
		this.setPresetDefinitions(structure, presets)

		this.#startClient()
	}

	async destroy(): Promise<void> {
		this.#stopClient()
	}

	async configUpdated(config: ModuleConfig): Promise<void> {
		const prev = this.config
		this.config = config
		if (!this.#client || prev.host !== config.host || Number(prev.port) !== Number(config.port)) {
			this.#startClient()
		} else if (this.label !== this.#lastLabel) {
			this.#lastLabel = this.label
			this.#client.setName(this.label)
		}
	}

	getConfigFields(): SomeCompanionConfigField[] {
		return GetConfigFields()
	}

	#startClient(): void {
		this.#stopClient()
		const host = String(this.config.host ?? '').trim()
		const port = Math.round(Number(this.config.port ?? DEFAULT_PORT))
		if (!host || !Number.isFinite(port) || port < 1 || port > 65535) {
			this.updateStatus(InstanceStatus.BadConfig, 'Set the host and port of LifeCG.app')
			return
		}

		const client = new LifeCGClient({ host, port, name: this.label })
		client.on('status', (status, message) => this.updateStatus(STATUS_MAP[status], message))
		client.on('state', (state) => this.#applyState(state, false))
		client.on('serverError', (message) => this.log('warn', `LifeCG.app: ${message}`))
		client.on('log', (level, message) => this.log(level, message))
		this.#client = client
		client.start()
	}

	#stopClient(): void {
		if (!this.#client) return
		this.#client.removeAllListeners()
		this.#client.stop()
		this.#client = null
	}

	#applyState(state: LifeCGState, force: boolean): void {
		this.#state = state
		const sig = recentSignature(state)
		if (force || sig !== this.#recentSig) {
			// Dropdowns embed the Recent list, so re-publish the definitions whenever it changes
			this.#recentSig = sig
			this.setActionDefinitions(
				buildActionDefinitions({
					getState: () => this.#state,
					send: (msg) => this.#client?.send(msg) ?? false,
					log: (level, message) => this.log(level, message),
				})
			)
			this.setFeedbackDefinitions(buildFeedbackDefinitions(() => this.#state))
		}
		this.setVariableValues(stateToVariables(state))
		this.checkFeedbacks('on_air', 'title_on_air')
	}
}
