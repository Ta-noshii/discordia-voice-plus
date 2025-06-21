---@diagnostic disable: different-requires
--[=[
@c VoiceConnection
@d Represents a connection to a Discord voice server.
]=]
local discordia = require("discordia")
local class = discordia.class
local classes = class.classes

local VoiceUserMap = require('containers/VoiceUserMap')

local ffi = require('ffi')
local constants = require('discordia/libs/constants')

local CHANNELS = 2
local SAMPLE_RATE = 48000 -- Hz
local FRAME_DURATION = 20 -- ms

local MS_PER_S = constants.MS_PER_S

local FRAME_SIZE = SAMPLE_RATE * FRAME_DURATION / MS_PER_S -- 960
local MAX_FRAME_SIZE = FRAME_SIZE * CHANNELS * 2 -- 3840

local ffi_string = ffi.string
local unpack = string.unpack -- luacheck: ignore

---@class VoiceConnection
---@field map VoiceUserMap The VoiceUserMap for this connection.
---<!tag:patch>
local VoiceConnection = classes.VoiceConnection
local get = VoiceConnection.__getters

function VoiceConnection:__init(channel)
	self._channel = channel
	self._pending = {}
	self._map = VoiceUserMap(self)
end

---The function that handles the UDP packets received by the voice connection.
---@param packet string The UDP packet received by the voice connection.
function VoiceConnection:onAudioPacket(packet)
	local socket = self._socket

	if not socket then
		return
	end

	local ssrc = unpack('>I4', packet, 9)
	local voiceUser = self._map:find(function(voiceUser)
		return voiceUser._audioSSRC == ssrc
	end)

	if not voiceUser then return self.client:warning('Received audio data for unknown SSRC %i', ssrc) end
	voiceUser:setSpeaking()

	if not voiceUser._subscribed then return end
	local key = self._key

	if not key then
		return socket:error('Secret key not available')
	end

	local message, sequence, timestamp, ssrc = self:_parseAudioPacket(packet, self._key)

	if message then -- opus decode
		local success, pcm = pcall(voiceUser.decoder.decode, voiceUser.decoder, message, #message, FRAME_SIZE, MAX_FRAME_SIZE)

		if not success then
			return socket:error('Opus decode failed: %s', pcm) -- error message
		end

		local last_sequence = voiceUser._last_seq or 0
		if (last_sequence > sequence) and (last_sequence - sequence <= 10) then -- ignore out of order packets
			return socket:warning('[#%i | %s] Ignored out of order packet', ssrc, voiceUser.member.name)
		else
			voiceUser._last_seq = sequence
		end

		voiceUser:emit('pcm', pcm, MAX_FRAME_SIZE, sequence, last_sequence)
		voiceUser:emit('pcmString', ffi_string(pcm, MAX_FRAME_SIZE))
	else
		socket:error('Decode packet failed %s', sequence) -- error message
	end
end

function get.map(self)
	return self._map
end

return VoiceConnection
