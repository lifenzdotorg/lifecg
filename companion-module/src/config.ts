import { Regex, type SomeCompanionConfigField } from '@companion-module/base'

export const DEFAULT_PORT = 9123

export type ModuleConfig = {
	host: string
	port: number
}

export function GetConfigFields(): SomeCompanionConfigField[] {
	return [
		{
			type: 'static-text',
			id: 'info',
			label: 'LifeCG.app',
			width: 12,
			value:
				'Connects to LifeCG.app over WebSocket (ws://host:port/ws). Use 127.0.0.1 when Companion runs on the graphics Mac, otherwise that Mac\'s IP address or hostname. The port is shown in the app\'s settings (default 9123).',
		},
		{
			type: 'textinput',
			id: 'host',
			label: 'Host (IP or hostname)',
			width: 8,
			default: '127.0.0.1',
			regex: Regex.HOSTNAME,
		},
		{
			type: 'number',
			id: 'port',
			label: 'Port',
			width: 4,
			min: 1,
			max: 65535,
			default: DEFAULT_PORT,
			asInteger: true,
		},
	]
}
