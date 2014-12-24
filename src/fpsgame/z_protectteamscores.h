#ifndef Z_PROTECTTEAMSCORES_H
#define Z_PROTECTTEAMSCORES_H

VAR(protectteamscores, 0, 0, 2);

int z_calcteamscore(hashset<teaminfo> *&ti, const char *team, int fragval)
{
    if(!ti) ti = new hashset<teaminfo>(1<<7);
    teaminfo *t = ti->access(team);
    if(!t)
    {
        t = &ti->operator[](team);
        copystring(t->team, team, sizeof(t->team));
        t->frags = 0;
    }
    t->frags += fragval;
    return t->frags;
}

void z_setteaminfos(hashset<teaminfo> *&dst, hashset<teaminfo> *src)
{
    if(!src) { DELETEP(dst); return; }
    if(dst) dst->clear();
    int count = 0;
    enumerates(*src, teaminfo, t,
        if(t.frags) { z_calcteamscore(dst, t.team, t.frags); count++; }
    );
    if(dst && !count) DELETEP(dst);
}

bool z_acceptfragval(clientinfo *ci, int fragval)
{
    switch(protectteamscores)
    {
        case 0: default: return true;
        case 1: return fragval > 0 ? (ci->state.frags > 0) : (ci->state.frags >= 0);
        case 2:
        {
            int teamscore = z_calcteamscore(ci->state.teaminfos, ci->team, fragval);
            return fragval > 0 ? (teamscore > 0) : (teamscore >= 0);
        }
    }
}

#endif // Z_PROTECTTEAMSCORES_H