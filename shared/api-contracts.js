/**
 * Shared API Contracts between Type Duel Client (Godot) and Server (Node.js)
 * 
 * This file documents the API endpoints, request/response shapes, and socket events.
 * Keep this in sync with both server implementation and client expectations.
 */

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const VALID_CHARACTERS = ['Riven', 'Zephon', 'Liora'];
const VALID_SKILLS = ['quickslash', 'whiplash', 'soulbreak'];
const VALID_PASSIVES = ['reversal', 'jumble', 'phantom', 'stutter', 'erosion'];
const VALID_PHASES = ['lobby', 'skill_select', 'typing', 'resolving', 'finished'];

// ─────────────────────────────────────────────────────────────────────────────
// Room State Structure
// ─────────────────────────────────────────────────────────────────────────────

/**
 * @typedef {Object} Room
 * @property {string} code - Room code (uppercase, 4-6 chars typically)
 * @property {number} seq - Sequence number for change detection
 * @property {boolean} matchmaking - Whether this is a matchmaking room
 * @property {number} matchmaking_deadline_at - Unix ms deadline for selection
 * @property {string|number} host_id - Host user ID
 * @property {string} host_name - Host display name
 * @property {string|null} host_character - Host's selected character
 * @property {string[]} host_skills - Host's selected skills (max 2)
 * @property {string} host_passive - Host's selected passive
 * @property {string|number|null} guest_id - Guest user ID
 * @property {string|null} guest_name - Guest display name
 * @property {string|null} guest_character - Guest's selected character
 * @property {string[]} guest_skills - Guest's selected skills (max 2)
 * @property {string} guest_passive - Guest's selected passive
 * @property {'lobby'|'started'} status - Room status
 * @property {string} phase - Current game phase (see VALID_PHASES)
 * @property {number} phase_started_at - Unix ms when phase started
 * @property {number} typing_started_at - Unix ms when typing phase started
 * @property {number} first_finish_at - Unix ms when first player finished
 * @property {string|null} first_finish_by - 'host' | 'guest'
 * @property {number} round_id - Current round number
 * @property {number} host_hp - Host current HP
 * @property {number} guest_hp - Guest current HP
 * @property {number} host_streak - Host win streak
 * @property {number} guest_streak - Guest win streak
 * @property {number} host_mana - Host mana (0-10)
 * @property {number} guest_mana - Guest mana (0-10)
 * @property {number} host_progress - Host typing progress (0.0-1.0)
 * @property {number} guest_progress - Guest typing progress (0.0-1.0)
 * @property {number} host_typos - Host typo count
 * @property {number} guest_typos - Guest typo count
 * @property {string} host_skill - Host's chosen skill for this round
 * @property {string} guest_skill - Guest's chosen skill for this round
 * @property {boolean} host_skill_picked - Whether host has picked skill
 * @property {boolean} guest_skill_picked - Whether guest has picked skill
 * @property {boolean} host_wants_rematch - Host wants rematch
 * @property {boolean} guest_wants_rematch - Guest wants rematch
 * @property {Object|null} forfeit - Forfeit info if any
 * @property {string} forfeit.by - 'host' | 'guest'
 * @property {string} forfeit.reason - 'leave' | 'disconnect_timeout'
 * @property {Object|null} disconnect - Disconnect tracking
 * @property {number} disconnect.host_suspect_at - Unix ms when host suspected offline
 * @property {number} disconnect.guest_suspect_at - Unix ms when guest suspected offline
 * @property {number} created_at - Unix ms room creation time
 * @property {number} last_activity_at - Unix ms last activity
 * @property {number} server_now - Server timestamp (added in snapshots)
 */

// ─────────────────────────────────────────────────────────────────────────────
// REST API Endpoints
// ─────────────────────────────────────────────────────────────────────────────

/**
 * POST /api/rooms/create
 * Request: { user_id, display_name, code }
 * Response: { ok: true, code: string }
 */

/**
 * POST /api/rooms/join
 * Request: { user_id, display_name, code }
 * Response: { ok: true, room: Room }
 */

/**
 * GET /api/rooms/:code
 * Response: Room (with server_now)
 */

/**
 * DELETE /api/rooms/:code (host closes)
 * Response: { ok: true } | { ok: true, room: Room } (if in-game forfeit)
 */

/**
 * POST /api/rooms/:code/leave (either player leaves)
 * Response: { ok: true } | { ok: true, room: Room } (if in-game forfeit)
 */

/**
 * PATCH /api/rooms/:code/select
 * Request: { user_id, character?, skills?, passive? }
 * Response: { ok: true }
 */

/**
 * POST /api/rooms/:code/start
 * Response: { ok: true, room: Room } | { ok: true, already_started: true, room: Room }
 */

/**
 * PATCH /api/rooms/:code/phase
 * Request: { user_id, phase, round_id? }
 * Response: { ok: true, room: Room }
 */

/**
 * PATCH /api/rooms/:code/progress
 * Request: { user_id, progress?, typos?, mana?, send_mutation?, chosen_skill? }
 * Response: { ok: true } | { ok: true, room: Room } (if phase transitioned)
 */

/**
 * PATCH /api/rooms/:code/hp
 * Request: { user_id, host_hp, guest_hp, host_streak?, guest_streak? }
 * Response: { ok: true, room: Room }
 */

/**
 * PATCH /api/rooms/:code/rematch
 * Request: { user_id, wants_rematch: boolean }
 * Response: { ok: true, rematch_ready: boolean, room: Room }
 */

/**
 * POST /api/rooms/queue/join
 * Request: { user_id, display_name }
 * Response: { ok: true, role: 'waiting' } | { ok: true, role: 'host'|'guest', room: Room }
 */

/**
 * POST /api/rooms/queue/leave
 * Request: { user_id }
 * Response: { ok: true }
 */

/**
 * GET /api/rooms/queue/status
 * Response: { status: 'idle'|'waiting'|'matched', room?: Room }
 */

// ─────────────────────────────────────────────────────────────────────────────
// Socket Events (WebSocket)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Server -> Client Events:
 * 
 * 'room_update': { room: Room }
 *   - Sent when room state changes significantly
 * 
 * 'opponent_forfeit': { by: 'host'|'guest', reason: string }
 *   - Sent when opponent forfeits
 * 
 * 'match_ended': { reason: string }
 *   - Sent when match ends (HP reached 0)
 */

/**
 * Client -> Server Events:
 * 
 * 'join_room': { code: string, user_id: string|number }
 *   - Join a room for real-time updates
 * 
 * 'leave_room': { code: string }
 *   - Leave room updates
 */

// ─────────────────────────────────────────────────────────────────────────────
// Mutation Types (Skills that affect opponent)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Mutation types sent via send_mutation in progress updates:
 * 
 * { type: 'jumble' } - Jumble opponent's sentence
 * { type: 'stutter' } - Add stutter to opponent's sentence
 * { type: 'reversal' } - Reversal effect (finished first)
 */

// ─────────────────────────────────────────────────────────────────────────────
// Error Response Format
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Error responses follow this format:
 * { message: string }
 * 
 * HTTP Status Codes:
 * 400 - Bad Request (invalid input)
 * 403 - Forbidden (not authorized for this action)
 * 404 - Not Found (room/user not found)
 * 409 - Conflict (room full, already started, etc.)
 */

module.exports = {
    VALID_CHARACTERS,
    VALID_SKILLS,
    VALID_PASSIVES,
    VALID_PHASES,
};
