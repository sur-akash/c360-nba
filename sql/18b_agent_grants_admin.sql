/* ============================================================================
   18b_agent_grants_admin.sql  —  the one grant COCO_BUILDER cannot make
   ----------------------------------------------------------------------------
   ***RUN ON THE coco_admin CONNECTION***

       snow sql --connection coco_admin -f sql/18b_agent_grants_admin.sql

   Split out of sql/18 so that file stays re-runnable on the build connection.
   Same seam, and the same reasoning, as sql/10b and sql/10c.

   Cost: ZERO CREDITS.

   ----------------------------------------------------------------------------
   WHY THIS IS NEEDED, AND THE HOUR IT SAVES
   ----------------------------------------------------------------------------
   Cortex Agents resolve privileges from the querying user's DEFAULT role, not
   the role active in their session. On this account:

     SURAKASH's default role   ACCOUNTADMIN
     owner of every object     COCO_BUILDER
     COCO_BUILDER granted to   the USER only -- not into any role hierarchy

   ACCOUNTADMIN owning the C360_NBA database does not help, because the objects
   inside it are owned by the role that created them.

   The failure this produces is specific and misleading: the agent works when
   tested with USE ROLE COCO_BUILDER and fails through the Agents API with a
   privilege error on the search services. The natural next move is to go looking
   at the warehouse, the search service state or the agent spec, none of which is
   wrong.

   Granting COCO_BUILDER into SYSADMIN puts it in the standard hierarchy, and
   ACCOUNTADMIN inherits SYSADMIN, so one grant covers both. That is the
   conventional shape for a build role, and it is preferable to the two
   alternatives: duplicating every object grant onto ACCOUNTADMIN, which would
   then need maintaining in two places, or changing the user's default role, which
   is a change to an account object outside this project made for the convenience
   of one demo.

   USAGE on the agent is granted explicitly because it is not inherited through
   ownership of the schema.
   ============================================================================ */

USE ROLE ACCOUNTADMIN;

GRANT ROLE COCO_BUILDER TO ROLE SYSADMIN;
GRANT USAGE ON AGENT C360_NBA.APP.RM_COPILOT TO ROLE ACCOUNTADMIN;

/* Verify: COCO_BUILDER should now be granted to the user AND to SYSADMIN. */
SHOW GRANTS OF ROLE COCO_BUILDER;
