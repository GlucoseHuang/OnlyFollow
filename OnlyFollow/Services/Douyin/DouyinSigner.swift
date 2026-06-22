import Foundation
import WebKit

/// 抖音签名与 Session 管理器（单例）
///
/// 架构：
/// - 内嵌一个隐藏的 WKWebView，加载 https://www.douyin.com/
/// - 让抖音自己的 JS (byted_acrawler 等) 在 WebView 里跑起来
/// - App 需要签名时，通过 evaluateJavaScript 调抖音 JS 拿 X-Bogus / X-Gnarly
///
/// 关键点：
/// - WKWebView 用桌面 Chrome UA（iPhone UA 在很多端点会被 -352 风控）
/// - 第一次启动加载需要 ~3s（JS 文件大）；之后所有签名请求秒回
/// - websiteDataStore = .default() 让 cookie（ttwid/odin_tt/msToken）持久化
/// - UserDefaults 同时缓存 msToken/webid/verify_fp 以防 WebView 被系统回收
///
/// 调用入口：
/// - `ensureReady()` — app 启动后调一次，触发后台加载
/// - `sign(url:userAgent:body:)` — 给一个完整 URL 加上 X-Bogus / X-Gnarly
/// - `cookieString` — 拼好的 cookie header 值
@MainActor
final class DouyinSigner: NSObject {
    static let shared = DouyinSigner()

    /// a_bogus 算签 JS (从 saermart/DouyinLiveWebFetcher 拷贝, 19KB 纯函数, 无外部依赖)
    /// - 暴露 get_ab(queryString, userAgent) → a_bogus 字符串
    /// - 注入到 WKWebView 后挂到 window.__get_ab, 供 evaluateSign 调用
    /// - 抖音 live.douyin.com 的 enter 接口 2025-09 起改用 a-bogus 校验 (X-Bogus 不再够)
    static let aBogusJS: String = """
    function get_ab(dpf, ua) {
        function enc_sum(n_str) {
            function ir(t) {
                return ir = "function" == typeof Symbol && "symbol" == typeof Symbol.iterator ? function (t) {
                    return typeof t
                } : function (t) {
                    return t && "function" == typeof Symbol && t.constructor === Symbol && t !== Symbol.prototype ? "symbol" : typeof t
                },
                    ir(t)
            }
            function ur(t, r) {
                for (var e = 0; e < r.length; e++) {
                    var n = r[e];
                    n.enumerable = n.enumerable || !1,
                        n.configurable = !0, "value" in n && (n.writable = !0),
                        Object.defineProperty(t, sr(n.key), n)
                }
            }
            function sr(t) {
                var r = function (t, r) {
                    if ("object" != ir(t) || !t) return t;
                    var e = t[Symbol.toPrimitive];
                    if (void 0 !== e) {
                        var n = e.call(t, r || "default");
                        if ("object" != ir(n)) return n;
                        throw new TypeError("@@toPrimitive must return a primitive value.")
                    }
                    return ("string" === r ? String : Number)(t)
                }(t, "string");
                return "symbol" == ir(r) ? r : r + ""
            }
            var gr = function () {
                function t() {
                    if (function (t, r) {
                        if (!(t instanceof r)) throw new TypeError("Cannot call a class as a function")
                    }(this, t), !(this instanceof t)) return new t;
                    this.reg = new Array(8),
                        this.chunk = [],
                        this.size = 0,
                        this.reset()
                }
                return function (t, r, e) {
                    r && ur(t.prototype, r),
                        e && ur(t, e),
                        Object.defineProperty(t, "prototype", {
                            writable: !1
                        })
                }(t, [{
                    key: "reset",
                    value: function () {
                        this.reg[0] = 1937774191,
                            this.reg[1] = 1226093241,
                            this.reg[2] = 388252375,
                            this.reg[3] = 3666478592,
                            this.reg[4] = 2842636476,
                            this.reg[5] = 372324522,
                            this.reg[6] = 3817729613,
                            this.reg[7] = 2969243214,
                            this.chunk = [],
                            this.size = 0
                    }
                }, {
                    key: "write",
                    value: function (t) {
                        var r = "string" == typeof t ? function (t) {
                            var r = encodeURIComponent(t).replace(/%([0-9A-F]{2})/g, (function (t, r) {
                                return String.fromCharCode("0x" + r)
                            })),
                                e = new Array(r.length);
                            return Array.prototype.forEach.call(r, (function (t, r) {
                                e[r] = t.charCodeAt(0)
                            })),
                                e
                        }(t) : t;
                        this.size += r.length;
                        var e = 64 - this.chunk.length;
                        if (r.length < e) this.chunk = this.chunk.concat(r);
                        else
                            for (this.chunk = this.chunk.concat(r.slice(0, e)); this.chunk.length >= 64;) this._compress(this.chunk),
                                e < r.length ? this.chunk = r.slice(e, Math.min(e + 64, r.length)) : this.chunk = [],
                                e += 64
                    }
                }, {
                    key: "sum",
                    value: function (t, r) {
                        t && (this.reset(), this.write(t)),
                            this._fill();
                        for (var e = 0; e < this.chunk.length; e += 64) this._compress(this.chunk.slice(e, e + 64));
                        var n, o, i, u = null;
                        if ("hex" == r) {
                            u = "";
                            for (e = 0; e < 8; e++) u += (n = this.reg[e].toString(16), o = 8, i = "0", n.length >= o ? n : i.repeat(o - n.length) + n)
                        } else
                            for (u = new Array(32), e = 0; e < 8; e++) {
                                var s = this.reg[e];
                                u[4 * e + 3] = (255 & s) >>> 0,
                                    s >>>= 8,
                                    u[4 * e + 2] = (255 & s) >>> 0,
                                    s >>>= 8,
                                    u[4 * e + 1] = (255 & s) >>> 0,
                                    s >>>= 8,
                                    u[4 * e] = (255 & s) >>> 0
                            }
                        return this.reset(),
                            u
                    }
                }, {
                    key: "_compress",
                    value: function (t) {
                        if (t < 64) console.error("compress error: not enough data");
                        else {
                            for (var r = function (t) {
                                for (var r = new Array(132), e = 0; e < 16; e++) r[e] = t[4 * e] << 24,
                                    r[e] |= t[4 * e + 1] << 16,
                                    r[e] |= t[4 * e + 2] << 8,
                                    r[e] |= t[4 * e + 3],
                                    r[e] >>>= 0;
                                for (var n = 16; n < 68; n++) {
                                    var o = r[n - 16] ^ r[n - 9] ^ dr(r[n - 3], 15);
                                    o = o ^ dr(o, 15) ^ dr(o, 23),
                                        r[n] = (o ^ dr(r[n - 13], 7) ^ r[n - 6]) >>> 0
                                }
                                for (n = 0; n < 64; n++) r[n + 68] = (r[n] ^ r[n + 4]) >>> 0;
                                return r
                            }(t), e = this.reg.slice(0), n = 0; n < 64; n++) {
                                var o = dr(e[0], 12) + e[4] + dr(yr(n), n),
                                    i = ((o = dr(o = (4294967295 & o) >>> 0, 7)) ^ dr(e[0], 12)) >>> 0,
                                    u = br(n, e[0], e[1], e[2]);
                                u = (4294967295 & (u = u + e[3] + i + r[n + 68])) >>> 0;
                                var s = mr(n, e[4], e[5], e[6]);
                                s = (4294967295 & (s = s + e[7] + o + r[n])) >>> 0,
                                    e[3] = e[2],
                                    e[2] = dr(e[1], 9),
                                    e[1] = e[0],
                                    e[0] = u,
                                    e[7] = e[6],
                                    e[6] = dr(e[5], 19),
                                    e[5] = e[4],
                                    e[4] = (s ^ dr(s, 9) ^ dr(s, 17)) >>> 0
                            }
                            for (var c = 0; c < 8; c++) this.reg[c] = (this.reg[c] ^ e[c]) >>> 0
                        }
                    }
                }, {
                    key: "_fill",
                    value: function () {
                        var t = 8 * this.size,
                            r = this.chunk.push(128) % 64;
                        for (64 - r < 8 && (r -= 64); r < 56; r++) this.chunk.push(0);
                        for (var e = 0; e < 4; e++) {
                            var n = Math.floor(t / 4294967296);
                            this.chunk.push(n >>> 8 * (3 - e) & 255)
                        }
                        for (e = 0; e < 4; e++) this.chunk.push(t >>> 8 * (3 - e) & 255)
                    }
                }]),
                    t
            }();
            function dr(t, r) {
                return (t << (r %= 32) | t >>> 32 - r) >>> 0
            }
            function yr(t) {
                return 0 <= t && t < 16 ? 2043430169 : 16 <= t && t < 64 ? 2055708042 : void console.error("invalid j for constant Tj")
            }
            function br(t, r, e, n) {
                return 0 <= t && t < 16 ? (r ^ e ^ n) >>> 0 : 16 <= t && t < 64 ? (r & e | r & n | e & n) >>> 0 : (console.error("invalid j for bool function FF"), 0)
            }
            function mr(t, r, e, n) {
                return 0 <= t && t < 16 ? (r ^ e ^ n) >>> 0 : 16 <= t && t < 64 ? (r & e | ~r & n) >>> 0 : (console.error("invalid j for bool function GG"), 0)
            }
            enc_ = new gr;
            return enc_.sum(n_str);
        }
        function generate_lm_g_EP(ua_n = ua) {
            // function get_sz256f_2() {
            //     var r = [], k = 0, y = [0, 1, 0];
            //     for (var i = 255; i >= 0; i--) {
            //         r.push(i);
            //     }
            //     for (var i = 0; i < r.length; i++) {
            //         var a = r[i];
            //         k = (k * a + k + y[i % 3]) % 256;
            //         var b = r[k];
            //         r[i] = b, r[k] = a;
            //     }
            //     return r;
            // }
            var sz256f_2 = [233, 5, 1, 249, 162, 140, 57, 143, 19, 203, 254, 236, 99, 248, 93, 213, 79, 149, 216, 50, 145, 123, 240, 92, 23, 113, 130, 53, 235, 220, 201, 136, 223, 155, 190, 242, 243, 42, 52, 214, 151, 232, 97, 187, 163, 222, 30, 78, 47, 71, 49, 170, 247, 196, 25, 156, 183, 182, 217, 180, 147, 124, 208, 69, 215, 200, 161, 154, 91, 60, 133, 224, 119, 164, 221, 45, 98, 40, 186, 120, 51, 167, 38, 90, 194, 212, 129, 56, 87, 195, 144, 44, 75, 84, 81, 13, 197, 245, 36, 250, 115, 100, 105, 252, 206, 103, 112, 202, 114, 138, 192, 21, 116, 173, 181, 29, 82, 125, 141, 16, 211, 131, 225, 118, 31, 101, 77, 146, 135, 150, 62, 66, 67, 176, 0, 41, 46, 59, 107, 178, 43, 26, 189, 128, 8, 207, 166, 110, 3, 229, 85, 54, 63, 11, 32, 4, 234, 142, 72, 58, 33, 231, 12, 230, 102, 86, 70, 159, 226, 65, 237, 34, 244, 76, 132, 122, 111, 95, 179, 152, 175, 18, 177, 6, 126, 193, 219, 74, 134, 2, 61, 251, 191, 168, 209, 241, 137, 165, 88, 238, 160, 174, 153, 157, 199, 48, 22, 64, 246, 7, 139, 55, 27, 188, 148, 204, 127, 171, 89, 37, 172, 205, 121, 20, 28, 17, 169, 15, 227, 117, 80, 218, 198, 10, 106, 9, 39, 210, 104, 83, 109, 24, 108, 228, 184, 96, 185, 158, 14, 255, 239, 68, 94, 35, 73, 253];
            var k = 0, s = '';
            for (var i = 0; i < ua_n.length; i++) {
                var i1 = (i + 1) % 256;
                var a = sz256f_2[i1];
                k = (k + a) % 256;
                var c = sz256f_2[k];
                sz256f_2[i1] = c;
                sz256f_2[k] = a;
                s += String.fromCharCode(ua_n.charCodeAt(i) ^ sz256f_2[(a + c) % 256]);
            }
            return s;
        }
        function get_str_chr_list(one_str) {
            var r = [];  // 当然也可以用map实现
            for (var i = 0; i < one_str.length; i++) {
                r.push(one_str.charCodeAt(i));
            }
            return r;
        }
        function generate_szenc_head8p1() {
            var z = Math.random() * 65535;
            var a = z & 255;
            var b = (z >> 8) & 255, d = [];
            d.push((a & 170) | 1);
            d.push((a & 85) | 0);
            d.push((b & 170) | 0);
            d.push((b & 85) | 0);
            return d;
        }
        function generate_szenc_head8p2() {
            var a = ((Math.random() * 240) >> 0) + 1;
            var b = ((Math.random() * 255) >> 0) & 77, c = [1, 4, 5, 7], d = [];
            for (var i = 0; i < c.length; i++) {
                b = b | (1 << c[i]);
            }
            d.push((a & 170) | 1);
            d.push((a & 85) | 0);
            d.push((b & 170) | 0);
            d.push((b & 85) | 0);
            return d;
        }
        function get_szenc_tail(sz96_n) {
            key_sz_6 = [145, 110, 66, 189, 44, 211]
            var a = [];
            for (var i = 0; i < 94; i += 3) {
                var b = sz96_n[i];
                var c = sz96_n[i + 1];
                var d = sz96_n[i + 2];
                var e = (Math.random() * 1000) & 255;
                a.push((e & key_sz_6[0]) | (b & key_sz_6[1]));
                a.push((e & key_sz_6[2]) | (c & key_sz_6[3]));
                a.push((e & key_sz_6[4]) | (d & key_sz_6[5]));
                a.push(((b & key_sz_6[0]) | (c & key_sz_6[2])) | (d & key_sz_6[4]));
            }
            return a;
        }
        function generate_lm_g_ab_head4() {
            var s = '';
            var a = (Math.random() * 65535) & 255, b = (Math.random() * 40) >> 0;
            s += String.fromCharCode((a & 170) | 1);
            s += String.fromCharCode((a & 85) | 2);
            s += String.fromCharCode((b & 170) | 80);
            s += String.fromCharCode((b & 85) | 2);
            return s;
        }
        function get_list_str(one_list) {
            var s = '';
            for (var i = 0; i < one_list.length; i++) {
                s += String.fromCharCode(one_list[i]);
            }
            return s;
        }
        function get_lm_g_ab(lm_g_lm_n) {
            // function get_sz256() {
            //     var raw = [];
            //     var z = 0;
            //     for (var i = 255; i >= 0; i--) {
            //         raw.push(i);
            //     }
            //     for (var i = 0; i < raw.length; i++) {
            //         z += 211;
            //         var a = z % 256;
            //         var b = raw[i];
            //         var c = raw[a];
            //         raw[a] = b;
            //         raw[i] = c;
            //         z = (raw[i + 1] * a) + a;
            //     }
            //     return raw;
            // }
            var fixed_sz256_n = [194, 249, 255, 165, 114, 67, 251, 187, 174, 231, 164, 237, 124, 235, 68, 83, 206, 79, 142, 167, 30, 77, 0, 93, 118, 29, 32, 161, 2, 171, 243, 179, 42, 170, 223, 119, 98, 222, 219, 57, 245, 135, 197, 13, 186, 202, 88, 184, 214, 12, 76, 185, 116, 74, 54, 53, 104, 208, 158, 163, 82, 173, 253, 240, 172, 63, 191, 207, 25, 15, 201, 203, 215, 236, 183, 233, 145, 127, 72, 6, 16, 10, 228, 35, 232, 159, 66, 168, 108, 71, 217, 75, 33, 155, 112, 128, 36, 24, 138, 50, 211, 23, 107, 14, 247, 137, 175, 242, 234, 157, 199, 49, 139, 85, 81, 17, 180, 86, 120, 78, 51, 205, 169, 148, 181, 3, 94, 106, 252, 220, 150, 47, 151, 84, 212, 18, 149, 182, 100, 123, 121, 156, 154, 152, 126, 204, 60, 133, 132, 248, 7, 91, 58, 59, 20, 97, 113, 117, 131, 46, 250, 224, 21, 73, 146, 31, 193, 69, 140, 125, 9, 39, 89, 5, 65, 141, 218, 80, 1, 70, 64, 166, 87, 189, 55, 147, 22, 26, 143, 61, 144, 99, 92, 44, 129, 130, 227, 103, 90, 192, 198, 244, 136, 101, 246, 153, 56, 38, 4, 178, 221, 162, 134, 37, 111, 28, 216, 96, 102, 210, 254, 196, 195, 230, 241, 62, 11, 122, 52, 40, 41, 229, 226, 225, 48, 45, 160, 105, 8, 115, 34, 43, 209, 95, 239, 190, 188, 109, 27, 19, 176, 213, 200, 238, 177, 110];
            // var fixed_sz256_n = get_sz256();
            var z = 0;
            var st = "";
            for (var i = 0; i < lm_g_lm_n.length; i++) {
                var a = (i + 1) % 256;
                var c = fixed_sz256_n[a];
                z = (z + c) % 256;
                var e = fixed_sz256_n[z];
                fixed_sz256_n[a] = e;
                fixed_sz256_n[z] = c;
                var g = (e + c) % 256;
                var h = lm_g_lm_n.charCodeAt(i);
                var j = fixed_sz256_n[g];
                var k = h ^ j;
                var l = String.fromCharCode(k);
                st += l;
            }
            return st;
        }
        function get_raw_ab(lm_get_ab_n, key_str = info_dic.s4) {
            var s = "", bw = 0;
            for (var i = 0; i < lm_get_ab_n.length; i += 3) {
                var cl = 16;
                var tcz = 0;
                var sof = 16515072;
                for (var j = i; j < i + 3; j++) {
                    if (j < lm_get_ab_n.length) {
                        var tlcy = lm_get_ab_n.charCodeAt(j) & 255;
                        tcz = tcz | (tlcy << cl);
                        cl -= 8;
                    } else {
                        bw += 1;
                    }
                }
                for (var h = 18; h >= (6 * bw); h -= 6) {
                    var tsz = tcz & sof;
                    s += key_str[tsz >> h];
                    sof = sof / 64;
                }
                s += '='.repeat(bw);
            }
            return s;
        }
        function get_random_number(min, max) {
            return Math.floor(Math.random() * (max - min + 1)) + min;
        }
        var info_dic = { "s0": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=",
            "s1": "Dkdpgh4ZKsQB80/Mfvw36XI1R25+WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=",
            "s2": "Dkdpgh4ZKsQB80/Mfvw36XI1R25-WUAlEi7NLboqYTOPuzmFjJnryx9HVGcaStCe=",
            "s3": "ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe",
            "s4": "Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe" }
        var t1 = Date.now();
        var s = [];
    
        var t2 = Date.now() - 1 + get_random_number(1, 3);
    
        var EP = get_raw_ab(generate_lm_g_EP(ua), key_str = info_dic.s3), eEP = enc_sum(EP);
    
        s.push("env_fx_list", "dpf_ua_dic", 1, 0, 8, "dpf", "", "ua", 6241, 6383, "1.0.1.19-fix.01", "ink", 3, "0X21_dic");  // 固定即可
    
        var t3 = Date.now() + get_random_number(4, 15);
        var eedp = enc_sum(enc_sum(dpf + 'dhzx'));
    
        s.push(t3, "reg_dic", 1, 0, eedp, "eedh", EP, eEP, t2, [3, 82], 41, [1, 0, 1, 0, 1]);
    
        var t4 = Date.now() + get_random_number(100, 1000);
    
        s1 = ((t4 - 1721836800000) / 1000 / 60 / 60 / 24 / 14) >> 0, szenc_o95_tail41 = [49, 52, 52, 49, 124, 56, 51, 56, 124, 49, 52, 52, 49, 124, 57, 49, 51, 124, 49, 52, 52, 49, 124, 57, 49, 51, 124, 49, 52, 52, 49, 124, 57, 54, 49, 124, 87, 105, 110, 51, 50];
    
        s.push(s1, 6, (t3 - t1 + 3) & 255, t3 & 255, (t3 >> 8) & 255, (t3 >> 16) & 255, (t3 >> 24) & 255, (t3 / 256 / 256 / 256 / 256) & 255);
    
        var s2 = (t3 / 256 / 256 / 256 / 256 / 256) & 255;
    
        s.push(s2, (s2 % 256) & 255, (s2 / 256) & 255, [211, 2, 5, 1, 129], 129, 0, 211, 2, 5, 1, 0, 0, 0, 0, eedp[9], eedp[18], 3, eedp[3], 82, 177, 4, 44, eEP[11], eEP[21], 5, eEP[5], t2 & 255, (t2 >> 8) & 255, (t2 >> 16) & 255, (t2 >> 24) & 255, (t2 / 256 / 256 / 256 / 256) & 255, (t2 / 256 / 256 / 256 / 256 / 256) & 255, 3, 97, 24, 0, 0, 239, 24, 0, 0, "screec_dic", "screen_str", szenc_o95_tail41, 41, 41, 0);
    
        var s3 = ((t3 + 3) & 255) + ',', s4 = get_str_chr_list(s3);
    
        s.push(s3, s4, s4.length, s4.length & 255, (s4.length >> 8) & 255);
    
        szenc_head8_p1 = generate_szenc_head8p1(), szenc_head8_p2 = generate_szenc_head8p2(), szenc_head8 = szenc_head8_p1.concat(szenc_head8_p2), s5 = [], s6 = [24, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 51, 52, 53, 55, 56, 57, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 79, 80, 84, 85];
        for (var i = 0; i < s6.length; i++) {
            s5.push(s[s6[i]]);
        }
        s.push(szenc_head8);
        var s7 = szenc_head8.concat(s5);
    
        var s8 = s7[0];
        for (var i = 1; i < s7.length; i++) {
            s8 = s8 ^ s7[i];
        }
        s.push(s8);
    
        enc_s_i = [34, 44, 56, 61, 73, 29, 70, 45, 35, 49, 38, 66, 51, 68, 28, 48, 64, 47, 30, 71, 26, 55, 31, 69, 59, 40, 62, 63, 27, 72, 41, 74, 57, 52, 42, 39, 33, 67, 53, 43, 65, 46, 36, 24, 60, 32, 79, 80, 84, 85];
        szenc_o95_head50 = [];
        for (var i = 0; i < enc_s_i.length; i++) {
            szenc_o95_head50.push(s[enc_s_i[i]]);
        }
        szenc_o95 = [];
        szenc_o95 = szenc_o95.concat(szenc_o95_head50, szenc_o95_tail41, s4, [s8]);
    
        szenc_tail = get_szenc_tail(szenc_o95);
        szenc = szenc_head8.concat(szenc_tail);
    
        lm_get_ab_head4 = generate_lm_g_ab_head4();
    
        var lm_get_lm = get_list_str(szenc);
        var lm_get_ab_tail = get_lm_g_ab(lm_get_lm);
        var lm_get_ab = lm_get_ab_head4 + lm_get_ab_tail
        return  get_raw_ab(lm_get_ab);
    }
    
"""

    /// 抖音桌面 Chrome UA（iPhone UA 在评论/直播接口会被 -352 风控）
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// 抖音首页 URL（首次加载后 byted_acrawler 就挂到 window 上）
    static let seedURL = "https://www.douyin.com/"

    /// ttwid 获取端点（公开，无签名要求）
    static let ttwidEndpoint = "https://ttwid.bytedance.com/ttwid/union/register/"

    private var webView: WKWebView?
    private var isLoaded = false
    private var loadStartedAt: Date?
    /// pending 的签名请求 — JS 还没就绪时排队用
    private var pendingResolvers: [CheckedContinuation<DouyinRequestSignatures, Error>] = []
    /// pending 的 cookie 查询
    private var pendingCookieResolvers: [CheckedContinuation<String, Error>] = []

    private override init() { super.init() }

    // MARK: - 生命周期

    /// App 启动后调一次：开始后台加载抖音首页
    /// - 不阻塞调用方；签名请求会在 JS 就绪后被 resolve
    func ensureReady() {
        guard webView == nil else { return }
        AppLogger.info("DouyinSigner: 启动 WKWebView 加载抖音首页")
        loadStartedAt = Date()

        let config = WKWebViewConfiguration()
        // .default() 让 cookie / cache 持久化（ttwid / odin_tt / msToken 自动 Set-Cookie）
        config.websiteDataStore = .default()
        // 用桌面 Chrome UA
        config.applicationNameForUserAgent = "Version/4.0 Chrome/120.0.0.0 Safari/537.36"

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent = Self.desktopUA
        wv.isHidden = true  // 隐藏,不占屏幕
        self.webView = wv

        // 加载抖音首页
        if let url = URL(string: Self.seedURL) {
            wv.load(URLRequest(url: url))
        }
    }

    /// 登录成功后调用：让首页 WebView 重新加载,以便拿到 sessionid/sessionid_ss 后的 webid/ttwid/odin_tt
    /// - 不会立即重新探活 isLoaded,等 didFinish 触发后走正常流程
    func refreshAfterLogin() {
        AppLogger.info("DouyinSigner: refreshAfterLogin, 重新加载首页 WKWebView")
        guard let webView else { return }
        isLoaded = false  // 期间签名请求会重新等 ready
        loadStartedAt = Date()
        webView.load(URLRequest(url: URL(string: Self.seedURL)!))
    }

    // MARK: - 对外 API

    /// 给外部用的纯 JS 求值 API（如 DouyinLiveSignature 调用抖音 JS 算签名）
    /// - 等就绪后 evaluateJavaScript 并返回字符串结果
    func evaluateScript(_ js: String) async throws -> String {
        if !isLoaded {
            await waitForReady()
        }
        guard let webView else { throw DouyinSignerError.notReady }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(js) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (value as? String) ?? "null")
            }
        }
    }

    /// 给 URL 加签名
    /// - 还没就绪时会等（async），不要在主线程卡住调用方
    func sign(url: String, userAgent: String = DouyinSigner.desktopUA, body: String = "") async throws -> DouyinRequestSignatures {
        // 优先用本地缓存的 msToken（避免每次 evaluateJavaScript 都从 cookie 读）
        let cachedMsToken = UserDefaults.standard.string(forKey: Keys.msToken) ?? ""
        if !isLoaded {
            // 等就绪
            await waitForReady()
        }
        return try await evaluateSign(url: url, userAgent: userAgent, body: body, msToken: cachedMsToken)
    }

    /// 拼好的 cookie 字符串（拼成 `k=v; k=v` 格式）
    /// - 从 WKWebView 的 cookie store 里读最新值
    var cookieString: String {
        get async {
            await readAllCookies()
        }
    }

    // MARK: - JS 求值

    private func waitForReady() async {
        guard let webView else { return }
        if isLoaded { return }

        // 用 withCheckedContinuation 等就绪通知
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 闭包内要用 token, 先声明
            var token: NSObjectProtocol!
            token = NotificationCenter.default.addObserver(
                forName: DouyinSigner.readyNotification,
                object: nil,
                queue: .main
            ) { _ in
                continuation.resume()
                if let t = token { NotificationCenter.default.removeObserver(t) }
            }
            // 如果加载已经开始但没完成,等;如果还没开始,触发
            if self.loadStartedAt == nil {
                self.ensureReady()
            }
            // 用 webView.isLoading 也不准; 直接 observe didFinish navigation
            _ = webView  // silence warning
        }
    }

    /// 调用抖音 JS 拿 X-Bogus + X-Gnarly
    /// - 抖音 JS 暴露 byted_acrawler.frontierSign({url, body, ua}) 返回的对象里有 X-Bogus 与 X-Gnarly
    /// - 旧 API byted_acrawler.sign 仅返回 X-Bogus,新版 frontierSign 同时含 Gnarly
    /// - 我们两个都试,优先 frontierSign
    private func evaluateSign(url: String, userAgent: String, body: String, msToken: String) async throws -> DouyinRequestSignatures {
        guard let webView else { throw DouyinSignerError.notReady }

        let js = """
        (function() {
            try {
                var url = \(jsString(url));
                var ua = \(jsString(userAgent));
                var body = \(jsString(body));
                var result = {xBogus: '', xGnarly: '', aBogus: '', msToken: ''};

                // 1. 优先用 frontierSign（新接口，同时含 X-Bogus + X-Gnarly）
                if (typeof window.byted_acrawler !== 'undefined') {
                    var ac = window.byted_acrawler;

                    // 1a. frontierSign — 返回 X-Bogus
                    if (typeof ac.frontierSign === 'function') {
                        try {
                            var sig = ac.frontierSign({url: url, userAgent: ua});
                            if (sig && typeof sig === 'object') {
                                if (sig['X-Bogus']) result.xBogus = sig['X-Bogus'];
                                if (sig.XBogus) result.xBogus = sig.XBogus;
                                if (sig['X-Gnarly']) result.xGnarly = sig['X-Gnarly'];
                                if (sig.XGnarly) result.xGnarly = sig.XGnarly;
                                if (sig['a-bogus']) result.aBogus = sig['a-bogus'];
                                if (sig.aBogus) result.aBogus = sig.aBogus;
                            } else if (typeof sig === 'string') {
                                result.xBogus = sig;
                            }
                        } catch(e) { /* fall through */ }

                        // 1b. 单独的 gnarly 调用（如果上面没拿到 Gnarly）
                        // 2025 起部分端点必须 X-Gnarly,这里要保证拿到 Gnarly 才能正常工作
                        // 参考实现: gnarly 入参 url 通常需要先拼上 X-Bogus
                        if (!result.xGnarly) {
                            if (typeof ac.gnarly === 'function') {
                                try {
                                    var gnarlyUrl = result.xBogus ? (url + (url.indexOf('?') >= 0 ? '&' : '?') + 'X-Bogus=' + result.xBogus) : url;
                                    var g = ac.gnarly({url: gnarlyUrl, body: body, userAgent: ua});
                                    if (typeof g === 'string') result.xGnarly = g;
                                    else if (g && (g['X-Gnarly'] || g.XGnarly)) result.xGnarly = g['X-Gnarly'] || g.XGnarly;
                                } catch(e) {}
                            }
                            // 老接口 sign — 只在 X-Bogus 没拿到时用
                            if (!result.xBogus && typeof ac.sign === 'function') {
                                try {
                                    var s = ac.sign({url: url, userAgent: ua});
                                    if (typeof s === 'string') result.xBogus = s;
                                    else if (s && s['X-Bogus']) result.xBogus = s['X-Bogus'];
                                } catch(e) {}
                            }
                        }
                    } else if (typeof ac.sign === 'function') {
                        // 没有 frontierSign（极老的抖音版本），fallback 到 sign
                        var s = ac.sign({url: url, userAgent: ua});
                        if (typeof s === 'string') result.xBogus = s;
                        else if (s && s['X-Bogus']) result.xBogus = s['X-Bogus'];
                    }
                    // 两条路径都要尝试拿 X-Gnarly（fallback 路径下也别漏）
                    if (!result.xGnarly && typeof ac.gnarly === 'function') {
                        try {
                            var gnarlyUrl = result.xBogus ? (url + (url.indexOf('?') >= 0 ? '&' : '?') + 'X-Bogus=' + result.xBogus) : url;
                            var g = ac.gnarly({url: gnarlyUrl, body: body, userAgent: ua});
                            if (typeof g === 'string') result.xGnarly = g;
                            else if (g && (g['X-Gnarly'] || g.XGnarly)) result.xGnarly = g['X-Gnarly'] || g.XGnarly;
                        } catch(e) {}
                    }
                }

                // 2. msToken — 优先 cookie / window, 都没有就随机生成 (107 位字母+数字+'-_')
                // 抖音服务端不校验 msToken 真伪, 任何客户端都能自己生成 (参考 saermart/DouyinLiveWebFetcher generateMsToken)
                var msToken = '';
                var cookieMatch = document.cookie.match(/msToken=([^;]+)/);
                if (cookieMatch) msToken = cookieMatch[1];
                if (!msToken && typeof window.msToken === 'string') msToken = window.msToken;
                if (!msToken) {
                    var msCharset = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
                    for (var i = 0; i < 107; i++) {
                        msToken += msCharset.charAt(Math.floor(Math.random() * msCharset.length));
                    }
                }
                result.msToken = msToken;

                // 3. a-bogus fallback: 用我们注入的 __get_ab 算
                // 入参是含 msToken 的 query string (saermart 验证)
                if (!result.aBogus && typeof window.__get_ab === 'function') {
                    try {
                        var queryStr = url;
                        var qIdx2 = url.indexOf('?');
                        if (qIdx2 >= 0) queryStr = url.substring(qIdx2 + 1);
                        queryStr += (queryStr ? '&' : '') + 'msToken=' + msToken;
                        result.aBogus = window.__get_ab(queryStr, ua);
                    } catch(e) { /* swallow */ }
                }

                return JSON.stringify(result);
            } catch(e) {
                return JSON.stringify({error: String(e)});
            }
        })()
        """

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            webView.evaluateJavaScript(js) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let s = value as? String {
                    continuation.resume(returning: s)
                } else {
                    continuation.resume(returning: "null")
                }
            }
        }

        // 解析
        guard let data = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DouyinSignerError.parseError("failed to parse signer result: \(result.prefix(200))")
        }
        if let errMsg = obj["error"] as? String {
            throw DouyinSignerError.jsError(errMsg)
        }
        let xBogus = obj["xBogus"] as? String ?? ""
        let xGnarly = obj["xGnarly"] as? String ?? ""
        let aBogus = obj["aBogus"] as? String ?? ""
        let msToken = obj["msToken"] as? String ?? ""

        // 缓存 msToken
        if !msToken.isEmpty {
            UserDefaults.standard.set(msToken, forKey: Keys.msToken)
        }

        AppLogger.info("DouyinSigner: sign done, xBogus=\(xBogus.prefix(8))... xGnarly=\(xGnarly.prefix(8))... aBogus=\(aBogus.prefix(8))... msToken=\(msToken.prefix(8))...")
        return DouyinRequestSignatures(
            xBogus: xBogus,
            xGnarly: xGnarly.isEmpty ? nil : xGnarly,
            aBogus: aBogus.isEmpty ? nil : aBogus,
            msToken: msToken
        )
    }

    /// 从 WKWebView cookie store 读所有 cookie 并拼接
    private func readAllCookies() async -> String {
        guard let webView else { return "" }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await store.allCookies()
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - ready notification
    static let readyNotification = Notification.Name("DouyinSigner.ready")

    // MARK: - Keys

    private enum Keys {
        static let msToken = "douyin.msToken"
        static let ttwid = "douyin.ttwid"
        static let webId = "douyin.webId"
        static let verifyFp = "douyin.verifyFp"
    }
}

// MARK: - 签名结果

struct DouyinRequestSignatures: Sendable {
    let xBogus: String           // URL query 参数 (X-Bogus=...)
    let xGnarly: String?         // URL query 参数或 HTTP header (X-Gnarly=...)
    let aBogus: String?          // 某些端点用 a-bogus 替代 X-Bogus
    let msToken: String          // URL query 参数或 cookie

    /// 拼成 query string 追加到 URL
    /// - 例: `&X-Bogus=DFSzswV...&X-Gnarly=MxESwhNL...&msToken=dkS_SWd...`
    /// - 如果 xGnarly 是 a-bogus 类型（取代 X-Bogus），则不重复添加
    func queryStringSuffix() -> String {
        var parts: [String] = []
        if !xBogus.isEmpty {
            parts.append("X-Bogus=\(xBogus)")
        }
        if let g = xGnarly, !g.isEmpty {
            parts.append("X-Gnarly=\(g)")
        }
        if let a = aBogus, !a.isEmpty {
            parts.append("a-bogus=\(a)")
        }
        if !msToken.isEmpty {
            parts.append("msToken=\(msToken)")
        }
        return parts.isEmpty ? "" : "&" + parts.joined(separator: "&")
    }
}

// MARK: - 错误

enum DouyinSignerError: LocalizedError {
    case notReady
    case parseError(String)
    case jsError(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .notReady: return "DouyinSigner 还没就绪"
        case .parseError(let m): return "DouyinSigner 解析失败: \(m)"
        case .jsError(let m): return "DouyinSigner JS 错误: \(m)"
        case .invalidURL: return "无效 URL"
        }
    }
}

// MARK: - WKNavigationDelegate

extension DouyinSigner: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 抖音首页加载完成 → 但 JS（byted_acrawler）可能还要再等几百毫秒才挂上 window
        // 我们用一个 delayed 一秒再 mark ready
        let startedAt = self.loadStartedAt
        Task { @MainActor in
            // 至少等 2s 让 JS 跑起来（抖音首页有 ~5MB JS,WebKit JIT 还要几百 ms）
            let elapsed = Date().timeIntervalSince(startedAt ?? Date())
            let waitMore = max(0.0, 2.0 - elapsed)
            try? await Task.sleep(nanoseconds: UInt64(waitMore * 1_000_000_000))

            // 探活 — 问 window.byted_acrawler 在不在
            let probe = """
            (function() {
                return JSON.stringify({
                    hasAcrawler: typeof window.byted_acrawler !== 'undefined',
                    acrawlerKeys: window.byted_acrawler ? Object.keys(window.byted_acrawler).slice(0, 20) : [],
                    hasMsToken: typeof window.msToken !== 'undefined',
                    cookieLen: document.cookie.length,
                    title: document.title
                });
            })()
            """
            // 注入 a_bogus 算签函数 (在 mark ready 之前, 这样 evaluateSign 调 __get_ab 时一定可用)
            webView.evaluateJavaScript("(function(){" + Self.aBogusJS + "; window.__get_ab = get_ab; return typeof window.__get_ab;})()") { _, err in
                if let err {
                    AppLogger.warning("DouyinSigner: 注入 a_bogus.js 失败, \(err.localizedDescription)")
                } else {
                    AppLogger.info("DouyinSigner: a_bogus.js 已注入 (window.__get_ab)")
                }
            }
            webView.evaluateJavaScript(probe) { result, _ in
                AppLogger.info("DouyinSigner: probe result = \(result ?? "nil")")
                self.isLoaded = true
                NotificationCenter.default.post(name: Self.readyNotification, object: nil)
                // 同时通知所有 pending resolvers
                let resolvers = self.pendingResolvers
                self.pendingResolvers.removeAll()
                AppLogger.info("DouyinSigner: ready, draining \(resolvers.count) pending signers")
                // pending resolvers 在 evaluateSign 中按需重新触发,这里只发通知
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        AppLogger.error("DouyinSigner: navigation failed: \(error.localizedDescription)")
        // 失败也标记就绪(签名请求会拿到空串,调用方能感知),避免永久 hang
        isLoaded = true
        NotificationCenter.default.post(name: Self.readyNotification, object: nil)
    }
}

// MARK: - JS String escape

private func jsString(_ s: String) -> String {
    // JS 单引号包裹 + 转义
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    return "'\(escaped)'"
}
