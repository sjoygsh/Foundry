/*
 * The Vorbis reference, as a developer tool (docs/design/music.md §3.5, ADR-0065).
 *
 *   vorbis_ref encode <in.wav> <out.ogg> <quality> <serial>
 *       16-bit PCM WAV, mono or stereo, to Ogg Vorbis at libvorbisenc's VBR quality
 *       (-0.1 to 1.0), with a fixed stream serial so the same input gives the same file.
 *   vorbis_ref decode <in.ogg> <out.wav>
 *       Ogg Vorbis to 16-bit PCM WAV through libvorbisfile's float output, each sample
 *       rounded to the nearest of x * 32768, clamped. Foundry's WAV decoder divides by
 *       32768, so the reference is exact to 2^-16.
 *
 * Built by scripts/m30/reference.py with `zig cc` against libogg 1.3.5 and libvorbis
 * 1.3.7 in a scratch directory. Never part of the build; nothing of it ships.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <vorbis/codec.h>
#include <vorbis/vorbisenc.h>
#include <vorbis/vorbisfile.h>

static void fail(const char *what) {
    fprintf(stderr, "vorbis_ref: %s\n", what);
    exit(1);
}

static uint32_t le32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void put16(FILE *f, uint16_t v) {
    fputc(v & 0xff, f);
    fputc(v >> 8, f);
}

static void put32(FILE *f, uint32_t v) {
    put16(f, v & 0xffff);
    put16(f, v >> 16);
}

static unsigned char *slurp(const char *path, long *len) {
    FILE *f = fopen(path, "rb");
    if (!f) fail("cannot open input");
    fseek(f, 0, SEEK_END);
    *len = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc((size_t)*len);
    if (!buf || fread(buf, 1, (size_t)*len, f) != (size_t)*len) fail("cannot read input");
    fclose(f);
    return buf;
}

/* The WAVs this reads are the scripts' own: RIFF, a 16-byte PCM fmt, then data. */
static int encode(const char *in, const char *out, float quality, int serial) {
    long len;
    unsigned char *wav = slurp(in, &len);
    if (len < 44 || memcmp(wav, "RIFF", 4) || memcmp(wav + 8, "WAVE", 4)) fail("not a WAV");
    int channels = 0, rate = 0;
    const unsigned char *data = NULL;
    long data_len = 0;
    for (long pos = 12; pos + 8 <= len;) {
        uint32_t size = le32(wav + pos + 4);
        if (!memcmp(wav + pos, "fmt ", 4)) {
            if (wav[pos + 8] != 1 || wav[pos + 22] != 16) fail("only 16-bit PCM is read");
            channels = wav[pos + 10];
            rate = (int)le32(wav + pos + 12);
        } else if (!memcmp(wav + pos, "data", 4)) {
            data = wav + pos + 8;
            data_len = size;
        }
        pos += 8 + size + (size & 1);
    }
    if (!data || channels < 1 || channels > 2) fail("no data, or not mono or stereo");
    long frames = data_len / (2 * channels);

    vorbis_info vi;
    vorbis_info_init(&vi);
    if (vorbis_encode_init_vbr(&vi, channels, rate, quality)) fail("encoder refused the settings");
    vorbis_comment vc;
    vorbis_comment_init(&vc);
    vorbis_comment_add_tag(&vc, "ENCODER", "foundry vorbis_ref (libvorbis 1.3.7)");
    vorbis_dsp_state vd;
    vorbis_block vb;
    vorbis_analysis_init(&vd, &vi);
    vorbis_block_init(&vd, &vb);
    ogg_stream_state os;
    ogg_stream_init(&os, serial);

    FILE *f = fopen(out, "wb");
    if (!f) fail("cannot open output");
    ogg_page og;
    ogg_packet header, comment, code;
    vorbis_analysis_headerout(&vd, &vc, &header, &comment, &code);
    ogg_stream_packetin(&os, &header);
    ogg_stream_packetin(&os, &comment);
    ogg_stream_packetin(&os, &code);
    while (ogg_stream_flush(&os, &og)) {
        fwrite(og.header, 1, (size_t)og.header_len, f);
        fwrite(og.body, 1, (size_t)og.body_len, f);
    }

    const long chunk = 1024;
    long done = 0;
    int eos = 0;
    while (!eos) {
        long n = frames - done < chunk ? frames - done : chunk;
        if (n == 0) {
            vorbis_analysis_wrote(&vd, 0);
        } else {
            float **buf = vorbis_analysis_buffer(&vd, (int)n);
            for (long i = 0; i < n; i++) {
                for (int c = 0; c < channels; c++) {
                    const unsigned char *s = data + ((done + i) * channels + c) * 2;
                    buf[c][i] = (int16_t)(s[0] | s[1] << 8) / 32768.0f;
                }
            }
            vorbis_analysis_wrote(&vd, (int)n);
            done += n;
        }
        while (vorbis_analysis_blockout(&vd, &vb) == 1) {
            vorbis_analysis(&vb, NULL);
            vorbis_bitrate_addblock(&vb);
            ogg_packet op;
            while (vorbis_bitrate_flushpacket(&vd, &op)) {
                ogg_stream_packetin(&os, &op);
                while (!eos && ogg_stream_pageout(&os, &og)) {
                    fwrite(og.header, 1, (size_t)og.header_len, f);
                    fwrite(og.body, 1, (size_t)og.body_len, f);
                    if (ogg_page_eos(&og)) eos = 1;
                }
            }
        }
    }
    fclose(f);
    ogg_stream_clear(&os);
    vorbis_block_clear(&vb);
    vorbis_dsp_clear(&vd);
    vorbis_comment_clear(&vc);
    vorbis_info_clear(&vi);
    free(wav);
    return 0;
}

static int decode(const char *in, const char *out) {
    OggVorbis_File vf;
    if (ov_fopen(in, &vf)) fail("libvorbisfile refused the input");
    vorbis_info *vi = ov_info(&vf, -1);
    int channels = vi->channels;
    long rate = vi->rate;
    long cap = 1 << 16, used = 0;
    int16_t *pcm = malloc((size_t)cap * sizeof *pcm);
    for (;;) {
        float **chans;
        int section;
        long n = ov_read_float(&vf, &chans, 1024, &section);
        if (n < 0) fail("libvorbisfile could not decode a packet");
        if (n == 0) break;
        if (section != 0) fail("a second section");
        while (used + n * channels > cap) {
            cap *= 2;
            pcm = realloc(pcm, (size_t)cap * sizeof *pcm);
        }
        for (long i = 0; i < n; i++) {
            for (int c = 0; c < channels; c++) {
                double v = nearbyint((double)chans[c][i] * 32768.0);
                if (v > 32767) v = 32767;
                if (v < -32768) v = -32768;
                pcm[used++] = (int16_t)v;
            }
        }
    }
    ov_clear(&vf);
    FILE *f = fopen(out, "wb");
    if (!f) fail("cannot open output");
    uint32_t bytes = (uint32_t)(used * 2);
    fwrite("RIFF", 1, 4, f);
    put32(f, 36 + bytes);
    fwrite("WAVEfmt ", 1, 8, f);
    put32(f, 16);
    put16(f, 1);
    put16(f, (uint16_t)channels);
    put32(f, (uint32_t)rate);
    put32(f, (uint32_t)(rate * channels * 2));
    put16(f, (uint16_t)(channels * 2));
    put16(f, 16);
    fwrite("data", 1, 4, f);
    put32(f, bytes);
    for (long i = 0; i < used; i++) put16(f, (uint16_t)pcm[i]);
    fclose(f);
    free(pcm);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 6 && !strcmp(argv[1], "encode")) return encode(argv[2], argv[3], (float)atof(argv[4]), atoi(argv[5]));
    if (argc == 4 && !strcmp(argv[1], "decode")) return decode(argv[2], argv[3]);
    fprintf(stderr, "usage: vorbis_ref encode <in.wav> <out.ogg> <quality> <serial>\n"
                    "       vorbis_ref decode <in.ogg> <out.wav>\n");
    return 2;
}
