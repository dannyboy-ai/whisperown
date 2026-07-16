"""Self-contained test for postprocess.py — no test framework.
Run: `python test_postprocess.py`. Exits non-zero if any fixture fails.

Fixtures use no dictionary-replaceable tokens, so output is dictionary-independent.
`input` is already-lowercased joined-text shape; it is fed straight to postprocess().
Every fixture is also asserted IDEMPOTENT: postprocess(postprocess(x)) == postprocess(x).
"""

import json
import sys

from postprocess import postprocess

fixtures = [
    # --- drop the trailing sentence period (casual output) -------------------
    {"input": "that's the ball game. ", "expected": "that's the ball game "},   # single sentence → no period
    {"input": "how are you? ", "expected": "how are you? "},                    # "?" carries tone → kept
    {"input": "that's wild! ", "expected": "that's wild! "},                    # "!" kept
    {"input": "first thing. second thing. ",
     "expected": "first thing. second thing "},                                # internal period kept, final dropped

    # --- trailing "thank you" hallucination (the dominant ~12% case) ---------
    {"input": "explain to me why silicone is better. thank you. ",
     "expected": "explain to me why silicone is better "},
    {"input": "hey, can you find what? my tiller replaces my tiller. the basement is in. it might be in the main repo. but i'm definitely curious. about it. thank you. ",
     "expected": "hey, can you find what? my tiller replaces my tiller. the basement is in. it might be in the main repo. but i'm definitely curious. about it "},
    {"input": "interesting. i am not having an issue in a group chat. thank you. ",
     "expected": "interesting. i am not having an issue in a group chat "},
    {"input": "can you triple check that these are going to be the two correct sizes? for this order. thank you. ",
     "expected": "can you triple check that these are going to be the two correct sizes? for this order "},
    {"input": "oh, my god. i'm so sorry. you ",
     "expected": "oh, my god. i'm so sorry "},

    # --- whole-record silence garbage -> empty -------------------------------
    {"input": "thank you. ", "expected": ""},
    {"input": ". ", "expected": ""},
    {"input": "thank you. thank you. thank you. thank you. . ", "expected": ""},

    # --- leading + stacked fillers -------------------------------------------
    {"input": "thank you. perhaps keeping these papers in a file will be good. thank you. thank you. ",
     "expected": "perhaps keeping these papers in a file will be good "},

    # --- mid-record isolated "thank you." ------------------------------------
    {"input": "so the big paper which is connected to the nsfw data. thank you. and... he doesn't necessarily... need two papers. ",
     "expected": "so the big paper which is connected to the nsfw data. and... he doesn't necessarily... need two papers "},

    # --- asterisk sound-tags + stray markers ---------------------------------
    {"input": "i'd say, uh, i don't even know what this stub layer is. i don't quite understand. *mario grunts* ",
     "expected": "i'd say, i don't even know what this stub layer is. i don't quite understand "},

    # --- spoken-filler ("uh"/"um") removal -----------------------------------
    {"input": "so, uh, yeah we should ship it. ", "expected": "so, yeah we should ship it "},
    {"input": "and uh the thing is basically done. ", "expected": "and the thing is basically done "},
    {"input": "uh, so basically i think it works. ", "expected": "so basically i think it works "},
    {"input": "um the whole record starts here. ", "expected": "the whole record starts here "},
    {"input": "well, uh, um, yeah let's go. ", "expected": "well, yeah let's go "},
    {"input": "that's the thing, um. anyway moving on. ", "expected": "that's the thing. anyway moving on "},
    {"input": "the plan uh is to keep it simple. ", "expected": "the plan is to keep it simple "},
    {"input": "uh um uh. ", "expected": ""},                                # whole-record filler
    {"input": "oh my gosh, bro. um. no, i want you to evaluate it. ",       # filler as its own segment
     "expected": "oh my gosh, bro. no, i want you to evaluate it "},
    {"input": "i'd say toss... um. next one then. ",                        # ellipsis must survive
     "expected": "i'd say toss... next one then "},
    # guards: filler-looking substrings inside real words / interjections
    {"input": "grab an umbrella, the number is huge and i assume so. ",
     "expected": "grab an umbrella, the number is huge and i assume so "},
    {"input": "uh-oh, that broke something. ", "expected": "uh-oh, that broke something "},
    {"input": "what is the compliance moderation proof package. i guess that's aether lab. . thank you. ",
     "expected": "what is the compliance moderation proof package. i guess that's aether lab "},
    {"input": "- bro, i know where my own thing is. is i'm looking for projects ",
     "expected": "bro, i know where my own thing is. is i'm looking for projects "},
    {"input": "he's just as smart as you, no offense. - ",
     "expected": "he's just as smart as you, no offense "},
    {"input": "thank you. thank you. *laughs* thank you. thank you. okay. i'm going to go to the next one. *sad music* thank you. wow. ",
     "expected": "okay. i'm going to go to the next one. wow "},

    # --- single-content-word boundary dedup ----------------------------------
    {"input": "there's just a lot of ideas. ideas in there. ",
     "expected": "there's just a lot of ideas in there "},
    {"input": "it's probably worth prioritizing. prioritizing this. ",
     "expected": "it's probably worth prioritizing this "},
    {"input": "they don't have any of the endura in stock, it appears. appears. so can you help ",
     "expected": "they don't have any of the endura in stock, it appears. so can you help "},
    {"input": "a hotel room. because it allows. allows us to remain in the driver's seat ",
     "expected": "a hotel room. because it allows us to remain in the driver's seat "},
    {"input": "i'm on the new network, which is great. great do i need to go to spec to cancel. ",
     "expected": "i'm on the new network, which is great do i need to go to spec to cancel "},
    {"input": "if it's not going to work. work. so try the three month plan ",
     "expected": "if it's not going to work. so try the three month plan "},
    {"input": "yeah, that's sort of the question. question of like what's even real ",
     "expected": "yeah, that's sort of the question of like what's even real "},

    # --- restart-stutter collapse (step 5b) ----------------------------------
    {"input": "i like the. the incumbents are going to win. ",
     "expected": "i like the incumbents are going to win "},
    {"input": "um, now the. the issue with this plan is cost. ",
     "expected": "now the issue with this plan is cost "},
    {"input": "and. and then we ship it. ", "expected": "and then we ship it "},   # conjunction restart
    {"input": "i. i think we should ship it. ", "expected": "i think we should ship it "},
    {"input": "the search is slow. the. the whole thing lags. ",
     "expected": "the search is slow. the whole thing lags "},      # second period is a real boundary
    {"input": "i'm. i'm basically done now. ", "expected": "i'm basically done now "},

    # -- stutter-collapse guards: legit boundaries + intentional doublings -----
    {"input": "so there are. there are options here. ",               # "are" can end a sentence -> untouched
     "expected": "so there are. there are options here "},
    {"input": "we need to plan for it. it should restart. ",          # object "it" then subject "it"
     "expected": "we need to plan for it. it should restart "},
    {"input": "blah, blah, blah. that is the gist. ",
     "expected": "blah, blah, blah. that is the gist "},
    {"input": "no, no, that is not what i meant. ", "expected": "no, no, that is not what i meant "},
    {"input": "it was twenty, twenty when i checked. ", "expected": "it was twenty, twenty when i checked "},
    {"input": "really, really good work on this. ", "expected": "really, really good work on this "},

    # ===== GUARD CASES: legit speech that MUST pass through unchanged =========

    # -- regressions the adversarial verifiers caught (locked-in guards) ------
    {"input": "thank you for the help, can you also look at this ",      # HIGH: leading-strip decap
     "expected": "thank you for the help, can you also look at this "},
    {"input": "thank you so much for building this. can you also add the dashboard link? ",
     "expected": "thank you so much for building this. can you also add the dashboard link? "},
    {"input": "thank you everyone for coming today ",
     "expected": "thank you everyone for coming today "},
    {"input": "great work. thank you everyone should know this ",        # HIGH: mid-record real
     "expected": "great work. thank you everyone should know this "},
    {"input": "nice. thank you bro that was fast ",                      # MED: address, not filler
     "expected": "nice. thank you bro that was fast "},
    {"input": "you. got it working now ",                                # MED: leading bare-you
     "expected": "you. got it working now "},
    {"input": "you. that's who did it ",
     "expected": "you. that's who did it "},
    {"input": "we use HTTP. HTTP is the protocol ",                      # LOW: repeated acronym
     "expected": "we use HTTP. HTTP is the protocol "},

    # -- other guards (interjections, function words, ambiguous repetition) ---
    {"input": "okay, thank you, man. it's so much faster than now. now we're just flying. ",
     "expected": "okay, thank you, man. it's so much faster than now. now we're just flying "},
    {"input": "brother, you have the pat. yes, thank you for not touching the blood database. it literally says it. thank you. ",
     "expected": "brother, you have the pat. yes, thank you for not touching the blood database. it literally says it "},
    {"input": "but we need to plan for it. it should basically restart with any time a new pr ",
     "expected": "but we need to plan for it. it should basically restart with any time a new pr "},
    {"input": "and the parents are too. too tired too. ",
     "expected": "and the parents are too. too tired too "},
    {"input": "this is already a document. yeah. yeah, this is a fine start. ",
     "expected": "this is already a document. yeah. yeah, this is a fine start "},
    {"input": "testing, testing, testing. testing, testing, testing, testing ",
     "expected": "testing, testing, testing. testing, testing, testing, testing "},
    {"input": "away entirely, is like a mega path. path 5 is a mega path. path 4 is basically the ",
     "expected": "away entirely, is like a mega path. path 5 is a mega path. path 4 is basically the "},
    {"input": "well, they don't pick up on that. that because we're too polite so part of this ",
     "expected": "well, they don't pick up on that. that because we're too polite so part of this "},
    {"input": "i think we've got to at least try building it. building it. ",
     "expected": "i think we've got to at least try building it. building it "},
    {"input": "here is a brief outline. line from another claude. he hasn't looked at it that closely. ",
     "expected": "here is a brief outline. line from another claude. he hasn't looked at it that closely "},
    {"input": "you got it. can you host it on the actual machine by any chance? can you just keep it on the mac mini? ",
     "expected": "you got it. can you host it on the actual machine by any chance? can you just keep it on the mac mini? "},
    {"input": "you must consider a hotel next time you go. come for a family get-together. ",
     "expected": "you must consider a hotel next time you go. come for a family get-together "},
    {"input": "you raise me up across the stormy sea. i am strong when i am alive. you raise me up. ",
     "expected": "you raise me up across the stormy sea. i am strong when i am alive. you raise me up "},
    {"input": "it's a much more casual thing. you let's actually do number two first. ",
     "expected": "it's a much more casual thing. you let's actually do number two first "},
    {"input": "one of the non the goo shibbles is around thank you. i have at least one if not two papers to write. ",
     "expected": "one of the non the goo shibbles is around thank you. i have at least one if not two papers to write "},
    {"input": "i'd say toss... . ",
     "expected": "i'd say toss... "},
    {"input": "okay. ", "expected": "okay "},
    {"input": "the government doesn't want you to know this, but you can buy your own phone. and own it out there. ",
     "expected": "the government doesn't want you to know this, but you can buy your own phone. and own it out there "},
    {"input": "here are the engagement numbers. on the discord. you can see messages are trending down and have been since about the 9th of may. and we might turn around quickly or something but ",
     "expected": "here are the engagement numbers. on the discord. you can see messages are trending down and have been since about the 9th of may. and we might turn around quickly or something but "},
    {"input": "send the version to the u.s. team and confirm it's 4.7 by the way. ",
     "expected": "send the version to the u.s. team and confirm it's 4.7 by the way "},
    {"input": "i can't-- remember what it's about. i'm okay with long paper if they're focused. ",
     "expected": "i can't-- remember what it's about. i'm okay with long paper if they're focused "},

    # -- idempotency stressors: adjacent mid-record fillers (the verifier bug) -
    {"input": "done. thank you. thank you. more text here ",
     "expected": "done. more text here "},
    {"input": "okay. thank you. thank you. thank you. so go. ",
     "expected": "okay. so go "},
]


def show(s):
    return json.dumps(s)


def main():
    failed = passed = 0
    print("== postprocess() joined-text fixtures ==")
    for fx in fixtures:
        got = postprocess(fx["input"])
        if got == fx["expected"]:
            passed += 1
        else:
            failed += 1
            print("FAIL", file=sys.stderr)
            print("  in:  ", show(fx["input"]), file=sys.stderr)
            print("  want:", show(fx["expected"]), file=sys.stderr)
            print("  got: ", show(got), file=sys.stderr)
        twice = postprocess(got)
        if twice == got:
            passed += 1
        else:
            failed += 1
            print("FAIL (idempotency)", file=sys.stderr)
            print("  in:   ", show(fx["input"]), file=sys.stderr)
            print("  once: ", show(got), file=sys.stderr)
            print("  twice:", show(twice), file=sys.stderr)

    print(f"\n{passed} passed, {failed} failed")
    if failed > 0:
        sys.exit(1)
    print("ALL PASS")


if __name__ == "__main__":
    main()
