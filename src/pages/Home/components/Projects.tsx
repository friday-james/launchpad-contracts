import {
  Box,
  Grid,
  makeStyles,
  Container,
  Theme,
  Typography,
  useMediaQuery,
  useTheme,
} from '@material-ui/core';
import React from 'react';
import ProjectCard, { ProjectCardType } from '../../../common/components/ProjectCard';

const useStyles = makeStyles((theme: Theme) => ({
  contentContainer: {
    display: 'flex',
    flexDirection: 'column',
    justifyContent: 'center',
    justifyItems: 'center',
  },
  container: {
    padding: 0,
  },
  title: {
    fontWeight: 800,
    marginBottom: 8,
  },
  projectsBox: {
    borderSpacing: '16px 0px',
  }
}));

const HowItWorksSection: React.FC = () => {
  const classes = useStyles();
  const theme = useTheme();
  const matches = useMediaQuery(theme.breakpoints.up('xs'));
  const smallScreen = useMediaQuery(theme.breakpoints.down('xs'));
  return (
    <Box
      className={classes.contentContainer}
      paddingY={8}
      paddingX={matches ? 2 : 8}
    >
      <Container maxWidth='lg' className={classes.container}>
        <Grid container>
          <Grid item xs={12}>
            <Typography variant='h1' align='center' className={classes.title}>
              IDO Projects
            </Typography>
            <Typography variant='h4' align='center' color='textSecondary'>
              Stay tuned for the upcoming IDO projects.
            </Typography>
            <Box marginTop={5} />
            <Box className={classes.projectsBox} display={smallScreen ? 'flex' : 'table'} flexWrap='wrap' alignItems="center" justifyContent="center" margin="auto">
              <ProjectCard
                type={ProjectCardType.BASIC}
                title='IDIA'
                description='IDIA token is the governance and access token for deal flow allocation from the multichain, decentralized incubator and launchpad.'
                image='/images/IDIA banner.svg'
              />
              <ProjectCard
                type={ProjectCardType.BASIC}
                title='OpenSwap'
                description='OpenSwap is a 1-stop DeFi hub that enables the most efficient on-chain and cross-chain swaps through unique liquidity queues, hybrid smart routing, and interchain bridging.'
                image='/images/OpenSwap banner.png'
              />
              <ProjectCard
                type={ProjectCardType.JOINCOMMUNITY}
                title='Exclusive Projects'
                description='Join the community for more updates!'
                image='/images/Coming Soon banner.png'
              />
            </Box>
          </Grid>
        </Grid>
      </Container>
    </Box>
  );
};

export default HowItWorksSection;
