/*
 * What an external networking consumer looks like: nothing but `foundry.h` and the table it
 * asks for. It calls every v5 networking entry point, so a parameter a C author cannot
 * express, or a type only Zig can construct, is a compile error here rather than a
 * discovery in somebody's game. It names no address, file or key: a session exists only by
 * a grant its host published.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "foundry.h"

static FoundryCursor cursor_begin(void)
{
    FoundryCursor c = FOUNDRY_CURSOR_BEGIN;
    return c;
}

FOUNDRY_EXPORT FoundryResult foundry_mod_init(FoundryGetApi get_api, FoundryMod self)
{
    const FoundryApi_v5 *api = (const FoundryApi_v5 *)get_api(FOUNDRY_API_VERSION_5);
    FoundryCursor cursor = cursor_begin();
    FoundryNetGrantInfo grant;
    FoundryNetSession session;
    FoundryNetSessionInfo session_info;
    FoundryNetChannelDesc channel;
    FoundryNetPeer peer;
    FoundryNetPeerInfo peer_info;
    FoundryNetEvent event;
    FoundryNetStats stats;
    FoundryNetDelivery delivery;
    FoundryNetCommand command;
    uint8_t buffer[256];
    uint64_t needed = 0;
    uint64_t number = 0;
    uint32_t count = 0;
    const char move[] = "move";

    (void)self;
    if (api == NULL) return FOUNDRY_ERR_UNSUPPORTED;
    if (api->version != FOUNDRY_API_VERSION_5) return FOUNDRY_ERR_UNSUPPORTED;

    /* The first published grant, and a session on it. */
    if (api->net_grant_next(&cursor, &grant) != FOUNDRY_OK) return FOUNDRY_ERR_NOT_FOUND;
    if (api->net_session_create(grant.id, &session) != FOUNDRY_OK) return FOUNDRY_ERR_REFUSED;

    memset(&channel, 0, sizeof channel);
    channel.id = foundry_content_id("external:commands", 17);
    channel.revision = 1;
    channel.max_payload_bytes = 64;
    channel.direction = FOUNDRY_NET_CLIENT_TO_SERVER;
    channel.delivery = FOUNDRY_NET_RELIABLE;
    (void)api->net_channel_register(session, &channel);
    channel.id = foundry_content_id("external:state", 14);
    channel.max_payload_bytes = 1024;
    channel.direction = FOUNDRY_NET_SERVER_TO_CLIENT;
    channel.delivery = FOUNDRY_NET_LATEST_STATE;
    (void)api->net_channel_register(session, &channel);
    cursor = cursor_begin();
    while (api->net_channel_next(session, &cursor, &channel) == FOUNDRY_OK) {
    }
    (void)api->net_session_info(session, &session_info);

    if (grant.role == FOUNDRY_NET_SERVER) {
        (void)api->net_session_listen(session);
        cursor = cursor_begin();
        while (api->net_peer_next(session, &cursor, &peer) == FOUNDRY_OK) {
            (void)api->net_peer_info(peer, &peer_info);
            if (peer_info.state == FOUNDRY_NET_PEER_SYNCHRONIZING) {
                (void)api->net_baseline_send(peer, 0, buffer, 0);
            } else if (peer_info.state == FOUNDRY_NET_PEER_ACTIVE) {
                (void)api->net_state_publish(peer, 1, buffer, 0);
            }
        }
        if (api->net_batch_admit(session, 1, &count) == FOUNDRY_OK && count > 0) {
            (void)api->net_batch_command(session, 0, &command);
            (void)api->net_batch_copy(session, 0, buffer, sizeof buffer, &needed);
        }
    } else {
        if (api->net_session_connect(session, &peer) == FOUNDRY_OK) {
            if (api->net_delivery_next(peer, &delivery) == FOUNDRY_OK &&
                api->net_delivery_take(peer, buffer, sizeof buffer, &needed, &delivery) == FOUNDRY_OK &&
                delivery.kind == FOUNDRY_NET_DELIVERY_BASELINE) {
                (void)api->net_baseline_acknowledge(peer, delivery.sequence, delivery.tick);
            }
            (void)api->net_command_send(peer, foundry_content_id("external:commands", 17), move,
                                        (uint32_t)(sizeof move - 1), &number);
            (void)api->net_peer_disconnect(peer, FOUNDRY_NET_DISCONNECT_APPLICATION);
        }
    }

    while (api->net_event_next(&event) == FOUNDRY_OK) {
        if (event.kind == FOUNDRY_NET_EVENT_ENDED && event.ending.kind == FOUNDRY_NET_ENDING_REFUSED &&
            event.ending.index != FOUNDRY_NET_NO_INDEX) {
            break;
        }
    }
    (void)api->net_stats(&stats);
    (void)api->net_session_close(session);
    return FOUNDRY_OK;
}
