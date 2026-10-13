#pragma once
// Portable preflight only; no Arduino dependency, no claimed LittleFS commit.
// Call AFTER looking up a persisted transaction receipt, and BEFORE the one
// storage commit. All inputs here come from strictly validated parsed data.
#include <array>
#include <cstdint>
#include <limits>
#include <string_view>
#include <vector>
namespace facesync {
struct Counter { std::string_view actor; std::uint64_t value; };
using Vector = std::vector<Counter>;
using Digest = std::array<std::uint8_t,32>;
inline bool valid(const Vector& v) {
    if (v.size()>64) return false;
    for (std::size_t i=0;i<v.size();++i) {
        if(v[i].actor.empty() || v[i].actor.size()>128 || v[i].value==0) return false;
        for(std::size_t j=0;j<i;++j) if(v[j].actor==v[i].actor) return false;
    }
    return true;
}
inline bool covers(const Vector& newer,const Vector& older) {
    for(const auto& old:older) {
        bool found=false;
        for(const auto& next:newer) if(next.actor==old.actor && next.value>=old.value) {found=true;break;}
        if(!found) return false;
    }
    return true;
}
struct State {
    std::string_view board,library,epoch,policy;
    std::uint64_t revision=0;
    Vector vector;
    Digest digest{};
    std::uint64_t settings=0;
    bool hasProjection=false, legacyDirty=false;
};
struct Candidate {
    std::string_view board,library,epoch,policy;
    std::uint64_t expectedRevision=0;
    Vector vector;
    Digest digest{};
    std::uint64_t settings=0;
    std::size_t faceCount=0,defaultCount=0,documentBytes=0,envelopeBytes=0;
    bool schemaValidated=false;
};
enum class Result { ok,identity,revision,dirty,invalid,capacity,policy,rollback,ambiguous };
inline Result preflight(const State& s,const Candidate& n) {
    if(n.board!=s.board || n.library!=s.library || n.epoch!=s.epoch) return Result::identity;
    if(n.expectedRevision!=s.revision || s.revision==std::numeric_limits<std::uint64_t>::max()) return Result::revision;
    if(s.legacyDirty) return Result::dirty;
    if(!n.schemaValidated || n.defaultCount==0 || !valid(n.vector) || n.policy.empty()) return Result::invalid;
    if(n.faceCount>128 || n.documentBytes>256u*1024u || n.envelopeBytes>256u*1024u) return Result::capacity;
    if(s.hasProjection) {
        if(n.policy!=s.policy) return Result::policy;
        bool newerVector=covers(n.vector,s.vector), sameVector=covers(s.vector,n.vector);
        if(!newerVector) return Result::rollback;
        // Projection-local settings (e.g. startupDefaultId, preset/user
        // interleaving) never move the vector, so an equal vector is not
        // automatically ambiguous: a strictly newer settings version is a
        // legitimate settings-only deployment.
        if(sameVector) {
            if(n.settings>s.settings) { /* allowed */ }
            else if(n.settings==s.settings) { if(n.digest!=s.digest) return Result::ambiguous; }
            else return Result::rollback;
        } else if(n.settings<s.settings) return Result::rollback;
    }
    return Result::ok;
}
}
